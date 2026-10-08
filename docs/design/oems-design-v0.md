# FIX OEMS: Design Proposal v0 (for discussion)

Status: **draft, nothing decided yet**. Decisions needed from Ahmed are in section 12.

---

## 1. What we are building

One platform that can play both sides of a FIX conversation:

| Mode                   | We are                              | Order flow                                            | Who acts                                                              |
| ---------------------- | ----------------------------------- | ----------------------------------------------------- | --------------------------------------------------------------------- |
| **Sell side (broker)** | Acceptor or initiator (per session) | Clients send NewOrderSingle / Cancel / Replace to us  | A trader in the UI acks, rejects, fills, cancels, or auto-rules do it |
| **Buy side**           | Acceptor or initiator (per session) | The UI creates orders, we send them to a broker/venue | The counterparty answers with ExecutionReports, we track them         |

**Business role and connection type are independent.** Each session has a `role` (SELL_SIDE: we receive orders and send executions; BUY_SIDE: we send orders and receive executions) and a `connectionType` (ACCEPTOR: we listen on a TCP port; INITIATOR: we connect out). All four combinations are supported. The order engine only looks at `role`; only the connection manager looks at `connectionType`.

Both modes share the same order model, state machine, validation pipeline, journal and UI. Only the _direction_ of the order differs.

Later (not v1, but the model allows it): a received client order becomes a **parent** and the trader routes **child** orders out on a buy-side session (care orders / agency desk).

---

## 2. The three services

```
 Browser (React + TS)
    │  HTTPS (REST commands)        WebSocket (live blotter, order events)
    ▼                               ▲
 ┌──────────────────────────────────┐
 │  OEMS Gateway  (UI backend / BFF) │  Spring Boot
 │  auth, entitlements, fan-out to   │
 │  many browsers, UI-shaped queries │
 └──────────────┬───────────────────┘
                │ gRPC: commands (unary) + event stream (server streaming)
                ▼
 ┌──────────────────────────────────────────────────────────┐
 │  FIX OEMS Core   (Spring Boot for wiring only)            │
 │                                                           │
 │  FIX adapter (QuickFIX/J)  ─►  inbound ring buffer         │
 │        ▲                         │                        │
 │        │                    single-writer order engine     │
 │        │                    (validation, state machine,    │
 │        └── outbound ◄─────   correlation, ER generation)   │
 │                                  │                        │
 │                          local journal (append-only)       │
 └──────────────────────────────────┬───────────────────────┘
                                    │ async, off the hot path
                                    ▼
                       PostgreSQL (orders, messages, lifecycle, sessions)
```

### Should the UI talk to the FIX backend directly?

**Recommendation: no, go through the UI backend (a "Backend for Frontend").**

- The FIX core should do one job: process FIX and order state quickly. Browser concerns (login, permissions per desk/user, dozens of WebSocket connections, slow or disconnected browsers, paging and search queries) would put unpredictable load and allocation on the same JVM that runs the FIX engine.
- A slow browser must never back-pressure the FIX engine. The BFF absorbs that: it subscribes to one event stream from the core and fans out to N browsers, dropping/conflating updates for slow clients.
- Security boundary: the core is never exposed to the internet; only the BFF is.
- The core stays UI-agnostic, so a second consumer (risk system, algo, another UI) can use the same gRPC API.

Cost: one extra network hop (~sub-millisecond on the same network). For human-clicked actions this is irrelevant.

### Protocols per communication type

| Path                                                                                   | Protocol                                                                          | Why                                                                                                                                        |
| -------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Browser → BFF commands (ack, reject, fill, new order, session start/stop, set seq num) | HTTPS REST (JSON)                                                                 | Request/response, easy to secure and audit. Every command carries a client-generated `commandId` so retries are idempotent.                |
| BFF → Browser live orders/events                                                       | WebSocket (plain WS with JSON, or STOMP)                                          | Server push, low overhead. Each message carries a per-stream sequence number so the browser can detect gaps and re-sync via REST snapshot. |
| BFF → Core commands                                                                    | gRPC unary                                                                        | Typed contract (protobuf), fast, versioned schema.                                                                                         |
| Core → BFF events                                                                      | gRPC server streaming (v1); Kafka/Aeron later if we need many consumers or replay | Ordered, typed stream with resume-from-sequence.                                                                                           |
| Core ↔ counterparties                                                                  | FIX over TCP (TLS optional) via QuickFIX/J                                        |                                                                                                                                            |
| Core → database                                                                        | Async writer fed from the journal                                                 | Keeps DB latency off the order path.                                                                                                       |

Your instinct (WebSocket for orders, HTTPS for session control) is right for the browser side. The only addition is that browser _commands on orders_ (Ack, Fill, …) should also be HTTPS, not WebSocket messages: you get a clear success/failure response per click, and the result then also arrives on the WebSocket as an order event.

---

## 3. Inside the FIX OEMS Core (where "fast" and "SOLID" live)

### 3.1 Hexagonal architecture (ports and adapters)

```
oems-domain        pure Java. Order model, state machine, validation rules,
                   correlation. No Spring, no QuickFIX/J, no DB imports.
oems-application   use cases: HandleNewOrder, AcceptOrder, FillOrder, ...
                   depends only on domain + port interfaces.
oems-fix-qfj       adapter: QuickFIX/J sessions, codecs per FIX version
oems-persistence   adapter: journal + PostgreSQL writer
oems-api-grpc      adapter: gRPC command/event API
oems-app           Spring Boot main, wiring, config
```

How the SOLID principles land concretely:

- **S**: one class per responsibility, e.g. `ClOrdIdUniquenessRule`, `OrderStateMachine`, `ExecutionReportFactory`, `SessionRegistry`.
- **O**: validation is a pipeline of `ValidationRule` implementations. A new rule (or a counterparty-specific one) is a new class registered in config, not an edit to an `if` chain. Asset classes add new `Instrument` types and rule sets the same way.
- **L**: every `OrderType`/`Instrument` subtype works anywhere the base type is expected (a multileg order goes through the same state machine as a single order).
- **I**: small ports: `FixOutbound`, `OrderJournal`, `OrderEventPublisher`, `SessionControl`, rather than one fat "FixService".
- **D**: the domain depends on interfaces; QuickFIX/J is an adapter behind `FixOutbound`/`FixInbound`. That is also what lets us swap the engine later (see 3.3).

### 3.2 Threading model: single writer

- QuickFIX/J receives a message on its session thread, does FIX-level validation (data dictionary), and hands it to a **ring buffer** (LMAX Disruptor or Agrona `ManyToOneRingBuffer`).
- One **order engine thread** (or one per shard, sharded by session or by order id) owns all order state. No locks, no shared mutable state, deterministic ordering.
- UI commands from gRPC go into the same ring buffer, so a trader's "Fill" and a client's "Cancel" for the same order are serialized; no race.
- Outputs (outbound FIX, journal entry, UI event) are published from that thread to their own consumer threads.

### 3.3 "Garbage-free" with QuickFIX/J: an honest picture

QuickFIX/J is **not** garbage-free. Each `quickfix.Message` is a tree map of field objects and `String`s; parsing and building messages allocates on every message. We cannot make the engine itself allocation-free without forking it.

What we _can_ do:

1. **Make our own code allocation-free on the hot path**: pre-allocated, pooled order objects; primitive collections (Agrona `Long2ObjectHashMap`, no boxing); `CharSequence`/`AsciiSequenceView` instead of new `String`s for ids; price as scaled `long` (not `BigDecimal`) internally; no streams/lambdas/logging string concatenation in hot loops; reusable flyweights for outbound messages.
2. **Make the remaining garbage cheap**: Java 21 with Generational ZGC gives sub-millisecond pauses; short-lived QFJ garbage dies young.
3. **Verify, not hope**: JMH micro-benchmarks plus Java Flight Recorder allocation profiling run in CI, with a budget ("allocations per order on our side = 0"). A commit that breaks the budget fails the build.
4. **Keep the door open**: because QFJ sits behind a port, we can later replace it with **Artio** (Real Logic, Apache 2.0, garbage-free, built on Aeron) or a commercial engine (Chronicle FIX, CoralFIX) without touching the domain.

Realistic numbers: QFJ handles thousands to tens of thousands of messages/second per instance with tens-of-microseconds to sub-millisecond internal latency when tuned. For a broker OEMS where a human clicks Ack/Fill, this is more than enough. If you need single-digit-microsecond tick-to-trade, that points to Artio from day one (decision D1).

Memory leaks: order state for terminal orders (Filled, Canceled, Rejected, Expired) is evicted from memory at end of day / after a configurable window and lives on in the DB; per-session maps are cleared on session removal; soak tests (multi-hour replay) in CI watch heap after GC.

---

## 4. Order tracking, correlation and lifecycle

### 4.1 Identifiers

| Id                             | Tag       | Owner                   | Purpose                                                                                         |
| ------------------------------ | --------- | ----------------------- | ----------------------------------------------------------------------------------------------- |
| ClOrdID                        | 11        | Client (sender)         | Unique per request within a session/day. Each cancel/replace has a **new** ClOrdID.             |
| OrigClOrdID                    | 41        | Client                  | Points to the ClOrdID of the _previous_ request in the chain (the one being canceled/replaced). |
| OrderID                        | 37        | Order owner (sell side) | Stays the same for the life of the order across all replaces.                                   |
| ExecID                         | 17        | Order owner             | Unique per ExecutionReport; used for dedup and busts/corrections (ExecRefID 19).                |
| SecondaryClOrdID / ClOrdLinkID | 526 / 583 | Client                  | Optional extra linkage.                                                                         |
| Internal `orderKey`            | n/a       | Us                      | Stable internal id (long) for the whole chain; primary key in the DB.                           |

The core keeps, per session (and per trading day):

- `ClOrdID → orderKey` (every ClOrdID ever used in the chain)
- `OrderID → orderKey`
- `orderKey → Order` (current state, current ClOrdID, pending request if any, cum qty, avg px, leaves qty, version)

Correlation of a new message: resolve by tag 41 (for cancel/replace), else tag 37, else tag 11. Every message, inbound and outbound, is then stored with its `orderKey`, which is what lets the UI show the **full lifecycle** of an order in one view.

### 4.2 Message-level rules (examples, to be finalised together)

Sell side, on receipt:

- **NewOrderSingle (D)** with a ClOrdID already used in this session/day → reject (ER with OrdRejReason=6 Duplicate order) unless PossResend(97)=Y and it is the same order, in which case ignore/re-send the last state.
- **OrderCancelReplaceRequest (G) / OrderCancelRequest (F)** where tag 41 is unknown → OrderCancelReject (9) with CxlRejReason=1 Unknown order. This is your "amend without a new order" case.
- G/F where tag 41 is not the **latest** ClOrdID of the chain → policy choice: reject, or accept by resolving via OrderID (many venues accept). Configurable per session.
- G/F on an order in a terminal state (Filled, Canceled, Rejected, Done for day/Expired) → OrderCancelReject CxlRejReason=0 Too late to cancel.
- G/F while another G/F is still pending → reject (CxlRejReason=3 Already pending) or queue, configurable.
- Replace that lowers OrderQty below CumQty → reject.
- Replace that changes immutable fields (Symbol, Side, …) → reject.
- PossDupFlag(43)=Y messages: dedup by MsgSeqNum + content, never double-process.

Buy side, on receipt of ExecutionReports:

- ER for an unknown ClOrdID/OrderID → alert, store as orphan, show in UI exceptions view.
- Duplicate ExecID → ignore (store, but do not apply).
- Fill exceeding leaves quantity, or CumQty going backwards → flag as a break.
- ExecType=H/G (Trade Cancel/Correct) → apply via ExecRefID.

### 4.3 State machine

States follow FIX OrdStatus (39): PendingNew, New, PartiallyFilled, Filled, PendingCancel, Canceled, PendingReplace, Replaced (as ExecType), Rejected, DoneForDay, Expired, Suspended, plus internal states such as `AwaitingTraderAck`.

The state machine is a table (current state × event → next state + outputs), defined as data, not nested `if`s. That makes it testable exhaustively and lets per-session Rules of Engagement override transitions. FIX 4.2 vs 4.4+ differences (ExecTransType, ExecType=Fill vs Trade) live in the version codec, not in the state machine.

### 4.4 Sell-side trader actions → what goes out on FIX

| UI action                                   | Outbound ExecutionReport (4.4 semantics)                               |
| ------------------------------------------- | ---------------------------------------------------------------------- |
| Ack                                         | ExecType=0 New, OrdStatus=New (optionally PendingNew first on receipt) |
| Reject                                      | ExecType=8 Rejected, OrdRejReason + Text                               |
| Partial fill / Fill                         | ExecType=F Trade, LastQty/LastPx, CumQty, AvgPx, LeavesQty             |
| Accept cancel                               | ExecType=4 Canceled                                                    |
| Reject cancel/replace                       | OrderCancelReject (9)                                                  |
| Accept replace                              | ExecType=5 Replaced, new ClOrdID, OrigClOrdID                          |
| Unsolicited cancel / Done for day / Restate | ExecType 4 / 3 / D                                                     |
| Bust / correct a fill                       | ExecType H / G with ExecRefID                                          |

Auto rules (configurable per session): auto-ack, auto-reject outside limits, auto-fill for simulators/test sessions.

---

## 5. Validation pipeline

Run in order, stop at the first hard failure:

1. **Session level (QFJ)**: checksum, body length, sequence numbers, CompIDs, SendingTime accuracy. Rejected with session Reject (3) automatically.
2. **Message structure (data dictionary)**: required tags, tag types, enum values, repeating groups, per FIX version and per counterparty. Rejected with Reject (3) or BusinessMessageReject (j).
3. **Correlation and state**: the rules in 4.2.
4. **Business rules**: instrument exists and is tradable, order type/TIF allowed for the instrument, price within collar, quantity/notional limits per client/account, lot size and tick size, market hours, client permissions, restricted list. Each is a `ValidationRule` class, enabled per session/client via config.

Each rejection records the rule that fired, which is shown in the UI and stored.

---

## 6. Asset classes

Internal model: an `Order` references an `Instrument`; instrument types are `Equity`, `Future`, `Option`, `Bond`, `Multileg` (a list of `Leg`s, each with its own instrument, side, ratio). Asset-specific fields live in typed extensions, not in one giant class.

| Asset class                                                               | FIX messages                                                                                                                                                                        | Notes                                                       |
| ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| Equity                                                                    | D, F, G, 8, 9                                                                                                                                                                       | Baseline                                                    |
| Futures                                                                   | same; SecurityType=FUT, MaturityMonthYear, contract multiplier                                                                                                                      |                                                             |
| Options                                                                   | same; PutOrCall, StrikePrice, MaturityDate, OpenClose (77), CoveredOrUncovered                                                                                                      |                                                             |
| Multileg (spreads, straddles, **buy-write** = stock leg + short call leg) | NewOrderMultileg (AB), MultilegOrderCancelReplace (AC), NoLegs (555) groups; ERs may be per strategy or per leg                                                                     | Leg-level fills need a leg-aware fill model.                |
| Fixed income                                                              | Price types (PriceType 423: percent of par, yield, spread), accrued interest, settlement date, often **RFQ** (QuoteRequest R / Quote S / QuoteResponse AJ) rather than plain orders | FI is the largest scope expansion; I suggest a later phase. |

---

## 7. All FIX versions, and FIX Orchestra

### Versions

QuickFIX/J supports FIX 4.0, 4.1, 4.2, 4.3, 4.4 and FIXT 1.1 with FIX 5.0 / SP1 / SP2. Approach:

- Each session declares its BeginString / DefaultApplVerID and its data dictionary.
- A **codec per version** translates between the wire message and one **canonical internal model** (semantically close to FIX 5.0 SP2). The domain never sees version differences.
- Counterparty-specific custom tags are handled by per-session dictionaries plus small mapping classes.

### FIX Orchestra

Orchestra is the machine-readable form of a counterparty's Rules of Engagement: messages, fields, code sets, **conditional rules** (e.g. "StopPx required when OrdType=Stop") and **workflows** (which response follows which request).

How we would use it:

1. One Orchestra file per counterparty (or per "RoE profile") is the source of truth.
2. From it we **generate** the QFJ data dictionary for that session (QuickFIX/J has Orchestra tooling for this) and our message-presence/conditional validation rules.
3. Later: drive parts of the state machine and the UI's order-entry form (which fields to show for which order type) from the same file.
4. Generate human-readable RoE documentation from it.

I would build the plain data-dictionary path first and add Orchestra in phase 2, designed for from day one.

---

## 8. Session management (no restart)

- Session definitions (CompIDs, host/port, version, dictionary, schedule, heartbeat, reset policy, role acceptor/initiator) are stored in the DB, not only in a `.cfg` file.
- Operations exposed via REST on the BFF → gRPC to core: **create, edit, start (logon), stop (logout), delete, set next sender/target sequence number, reset sequence numbers, view status and message log**.
- QuickFIX/J 2.x supports adding and removing sessions on a running acceptor/initiator (dynamic sessions), plus `logon()`, `logout()`, `setNextSenderMsgSeqNum()`, `setNextTargetMsgSeqNum()` and `reset()` on a live `Session`. I will confirm the exact API with a spike before we commit to it.
- Sequence number changes are allowed only when the session is logged out (or with an explicit "force" plus audit record), because changing them mid-session usually causes a resend storm.
- QFJ's own message store (for resends and seq nums) uses JDBC or file storage; that is separate from our business journal.
- Every session operation is audited (who, when, old value, new value).

---

## 9. Persistence

- **Journal (source of truth, hot path)**: every inbound and outbound message plus every state change is appended to a local append-only journal (Chronicle Queue or an Aeron archive) before it is acknowledged. On restart the in-memory order state is rebuilt by replaying the journal (event sourcing).
- **PostgreSQL (query store)**: an async writer consumes the journal and writes:
  - `fix_message` (raw message, parsed key tags, direction, session, seq num, timestamp, `order_key`)
  - `order` (current state snapshot)
  - `order_event` (lifecycle: each transition with cause)
  - `execution` (fills, with ExecID)
  - `session`, `session_audit`, `validation_failure`
  - Tables partitioned by trading date; old partitions archived.
- The UI's lifecycle view = `order_event` + `fix_message` for one `order_key`.

---

## 10. Engineering process

### Commits and documentation

- **Conventional Commits** (`feat:`, `fix:`, `perf:`, `refactor:`, `test:`, `docs:`) so the changelog and version number are generated automatically.
- Every PR has a template with: **What changed**, **Why**, **How to test**, **Test level touched** (see below), **Performance impact**.
- **Architecture Decision Records (ADRs)**: one short markdown file per significant decision (e.g. "ADR-003: use gRPC between BFF and core"). The decisions in section 12 become the first ADRs.
- Docs live in the repo (`docs/`), including the order state machine diagram, rules list, and per-counterparty RoE.

### "Major test / minor test"

There are two standard ideas that are probably what you mean:

1. **Semantic versioning: MAJOR.MINOR.PATCH.** Major = breaking change (e.g. API contract with the UI changes), minor = new feature, backward compatible, patch = bug fix. Conventional Commits drive this automatically.
2. **Test levels** (the "test pyramid"). Each PR states which levels it adds or touches:

| Level          | What                                                                                                                      | Runs                              |
| -------------- | ------------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| Unit           | Single class: a validation rule, a state transition, a codec                                                              | Every commit, seconds             |
| Component      | Whole core with fake FIX/DB: "NOS in → trader Ack → ER out"                                                               | Every commit                      |
| FIX acceptance | Scripted FIX conversations against a real QFJ session (QFJ ships an acceptance-test format we can reuse), per FIX version | Every PR                          |
| Integration    | Real PostgreSQL via Testcontainers, gRPC, BFF                                                                             | Every PR                          |
| End-to-end     | Browser (Playwright) → BFF → core → simulated counterparty                                                                | Nightly and before release        |
| Performance    | JMH benchmarks, latency histograms (HdrHistogram), allocation budget                                                      | Every PR (smoke) + nightly (full) |
| Soak           | Hours of replayed traffic, watch heap/latency drift                                                                       | Nightly / weekly                  |

A useful split: **"smoke" tests** (fast, must pass before merge) vs **"regression" tests** (full suite, nightly). That might also be the "major/minor" split you had in mind.

---

## 11. Proposed tech stack

| Layer            | Choice                                                                                                      |
| ---------------- | ----------------------------------------------------------------------------------------------------------- |
| Language/runtime | Java 25 LTS, Generational ZGC                                                                               |
| Core             | Spring Boot 3 (wiring/config only), QuickFIX/J 2.3.x, LMAX Disruptor, Agrona, Chronicle Queue, HdrHistogram |
| BFF              | Spring Boot 3 (WebFlux for WebSocket fan-out), Spring Security with OIDC                                    |
| API              | gRPC + protobuf between BFF and core; OpenAPI for REST                                                      |
| DB               | PostgreSQL 16+, Flyway migrations                                                                           |
| UI               | React + TypeScript, AG Grid for the high-update blotter                                                     |
| Tests            | JUnit 5, AssertJ, QFJ acceptance tests, Testcontainers, JMH, Playwright                                     |
| Build/CI         | Maven multi-module (with Maven wrapper), GitHub Actions, Docker images                                      |
| Observability    | Micrometer + Prometheus/Grafana, structured logs, OpenTelemetry traces (not on the hot path)                |

---

## 12. Decisions needed from Ahmed

| #   | Decision                   | My recommendation                                                                                                                                                                                                                  |
| --- | -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | FIX engine                 | QuickFIX/J behind a port, as you asked, with allocation-free code on our side; revisit Artio only if latency targets demand it.                                                                                                    |
| D2  | Latency/throughput targets | Proposal: p99 < 500 µs internal processing (receive → ER out, excluding human), 5,000 msg/s per instance sustained. Tell me your real numbers.                                                                                     |
| D3  | UI → FIX core path         | Via the BFF (UI backend), not direct.                                                                                                                                                                                              |
| D4  | Order ingress on sell side | Manual trader ack by default, auto-ack/auto-reject rules configurable per session.                                                                                                                                                 |
| D5  | v1 scope                   | Phase 1: equities single orders, sell side, FIX 4.2 + 4.4, session management, lifecycle view. Phase 2: buy side, futures/options, FIX 5.0 SP2. Phase 3: multileg (incl. buy-write), Orchestra. Phase 4: fixed income (incl. RFQ). |
| D6  | Tag 41 strictness          | Reject G/F whose tag 41 is unknown; for "not latest ClOrdID", configurable per session, default reject.                                                                                                                            |
| D7  | Database                   | PostgreSQL.                                                                                                                                                                                                                        |
| D8  | High availability          | v1 single instance with journal + fast restart; active/passive later.                                                                                                                                                              |
| D9  | Auth for the UI            | OIDC (e.g. Keycloak/Azure AD/Okta), with roles: trader, sales, ops (session control), read-only.                                                                                                                                   |
| D10 | Repository                 | One GitHub monorepo with the three services; a repo needs to be connected to this project before building starts.                                                                                                                  |

---

## 13. Where configuration lives (added 2026-10-03)

| Kind of config                                                                                                          | Where                                                                                    | Why                                         |
| ----------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------- |
| Sessions (CompIDs, host/port, FIX version, dictionary, schedule, heartbeat, reset policy, auto-ack rules)               | PostgreSQL, edited from the UI                                                           | Changes at runtime without restart; audited |
| Routing rules (which order goes to which destination session: by client, symbol, asset class, order type, size, venue…) | PostgreSQL, as data (conditions → destination)                                           | Editable by ops, versioned, testable        |
| Normalization rules (per-counterparty tag/value mappings, custom tags, defaults, symbology mapping)                     | PostgreSQL, as declarative mapping tables per session                                    | Same                                        |
| Validation rules config (limits, collars, allowed order types/TIF, restricted lists)                                    | PostgreSQL                                                                               | Same                                        |
| Data dictionaries / FIX Orchestra files                                                                                 | PostgreSQL (versioned blob) referenced by session; standard dictionaries ship in the jar | One versioned source per counterparty       |
| Infrastructure (DB URL, app ports, thread counts, journal paths)                                                        | `application.yml` + environment variables                                                | Deploy-time, not business config            |
| Secrets (DB password, FIX logon passwords, TLS keys)                                                                    | Secrets manager / environment, never plain text in the DB                                | Security                                    |

Rules for all business config:

- **Versioned**: every change creates a new version row (who, when, why, previous value); rollback = re-activate an old version.
- **Never read on the hot path**: the core loads config into memory at startup and on change. Each change builds a new immutable, pre-compiled snapshot that is swapped in atomically, so an order is always processed against one consistent version, and the order record stores which version it used.
- **Validated before activation**: a rule change is checked (and can be dry-run against recent orders) before it goes live.
- Optional later: export/import config as files in Git for review and promotion between environments (UAT → PROD).

## 14. What is stored in the database (added 2026-10-03)

Yes, every FIX message is stored: inbound and outbound, application and session-level (logon, heartbeat optional, resend, reject), raw text plus parsed key fields (session, direction, seq num, MsgType, ClOrdID, OrigClOrdID, OrderID, ExecID, timestamps) and the internal order key that links it to its order's lifecycle. Plus orders, order events, executions, validation failures, session audit, config versions.

How it gets there: messages are written first to the local append-only journal (microseconds), then an async writer batches them into PostgreSQL. A slow or briefly unavailable database never slows the FIX path, and nothing is lost because the journal is replayed.

QuickFIX/J's own message store (sequence numbers + messages kept for resend) is separate. v1: QFJ cached file store on local disk (fast). A shared JDBC store only becomes useful with active/passive failover, and it adds a DB write to every outbound message.

Retention: tables partitioned by trading day; retention period is a regulatory decision (often 5–7 years, e.g. MiFID II / SEC 17a-4).

## 15. Decisions log

| Date       | Decision (Ahmed)                                                                                             |
| ---------- | ------------------------------------------------------------------------------------------------------------ |
| 2026-10-03 | Start with the broker (sell side): receive orders, send executions.                                          |
| 2026-10-03 | FIX engine: QuickFIX/J only.                                                                                 |
| 2026-10-03 | Message retention: 1 year (daily partitions, drop partitions older than 1 year).                             |
| 2026-10-03 | Config in Git: later, not v1.                                                                                |
| 2026-10-03 | Sell side and buy side can each be acceptor or initiator: session `role` is independent of `connectionType`. |
| 2026-10-03 | Logging: Log4j2, highly configurable (section 16).                                                           |
| 2026-10-03 | QuickFIX/J upgrades must be easy (section 17); metrics exposed to the frontend (section 18).                 |
| 2026-10-03 | Build tool: Maven (multi-module, Maven wrapper).                                                             |
| 2026-10-03 | Java 25 LTS.                                                                                                 |
| 2026-10-03 | No routing rules in the broker phase: the broker is the end point and sends executions back.                 |

## 16. Logging (added 2026-10-03)

**Choice: Log4j2 (2.x), in all Java services.** For a low-latency FIX service it is the best mainstream option:

- **Async loggers** (LMAX Disruptor based): the business thread hands the event to a ring buffer and returns in well under a microsecond; a background thread does formatting and I/O.
- **Garbage-free mode**: with the Log4j2 API (parameterised messages, unboxed primitives, reusable events) logging creates no garbage in steady state, which matches our allocation budget. Logback (Spring Boot's default) is not garbage-free; SLF4J's varargs API allocates, so hot-path code uses the Log4j2 API directly, and libraries that use SLF4J are bridged to Log4j2.
- **Highly configurable**: XML/YAML config per environment, auto-reload on file change (`monitorInterval`), and log levels changed at runtime per package or per FIX session through Spring Boot Actuator `/loggers` (exposed in the UI's ops screen for admins).

Setup:

- `spring-boot-starter-log4j2`, Logback excluded.
- **Structured JSON logs** (`JsonTemplateLayout`) to stdout/files for ELK, Loki or Splunk, plus a human-readable pattern layout for local development.
- **Correlation fields** in every line: `traceId` (from the UI request, carried BFF → core), `sessionId`, `clOrdId`, `orderKey`, via the garbage-free ThreadContext map.
- **Separate log streams** via RoutingAppender: application log, per-FIX-session event log (logon, logout, resend, seq-num changes), error log, and a performance log (latency histograms emitted periodically, not per message).
- Rolling files by size and day, compressed, retention configurable.
- **Ring-buffer-full policy**: on the hot path, DEBUG/INFO events are discarded if the buffer is full rather than blocking the order thread; WARN/ERROR always kept.
- FIX message logging: every message is already stored via the journal → PostgreSQL, so QuickFIX/J's own message file logging is off by default and can be switched on per session for troubleshooting.
- Logs are for operations and troubleshooting. The business audit trail (orders, messages, session changes, config changes) lives in the database, not in logs.
- Log4j 3 is still pre-GA; stay on the latest 2.x and keep it patched (Log4Shell-class issues are why the version is pinned and monitored by Dependabot).

## 17. Easy QuickFIX/J upgrades (added 2026-10-03)

- **One module touches QuickFIX/J**: only `oems-fix-qfj` imports `quickfix.*`. Domain, application, API and persistence code never do; an ArchUnit test fails the build if anyone adds such an import elsewhere.
- **Thin wrappers over the QFJ APIs we use** (session control, session factory, acceptor session provider, message codec). An upgrade that changes one of them changes one wrapper class.
- **Public API only**: no subclassing of internal QFJ classes, no reflection, no forked copy of QFJ.
- **Our dictionaries are our files**: standard + per-counterparty dictionaries live in our repo (later generated from Orchestra), not patched QFJ resources.
- **Version in one place**: a property in the parent POM's `dependencyManagement`. Renovate/Dependabot opens a PR automatically when a new QFJ release ships.
- **Upgrade gate**: that PR runs the full upgrade suite: FIX acceptance tests for every FIX version we support, the session-control tests (add/start/stop/reset/seq nums, acceptor and initiator), and a benchmark comparison against the previous version (latency + allocations). Green suite = safe to merge; a red one points at the exact behaviour that changed.
- Major QFJ versions (e.g. 2.x → 3.x) can contain breaking changes; the adapter boundary confines them to one module.

## 18. Metrics shown in the frontend (added 2026-10-03)

How: Micrometer in each service → Prometheus endpoint (history, Grafana, alerts). The BFF also pushes a live metrics snapshot to the UI over WebSocket once a second for the dashboard. Hot-path counters are plain `long` fields owned by the engine thread and sampled by a metrics thread, so measuring adds no allocation or locking to order processing.

### Per FIX session (session health grid)

- Status: disconnected / connecting / logged on / logged out by us; role and connection type
- Last logon / logout time and reason; reconnect attempts
- Next sender / target sequence numbers
- Messages in / out per second and totals, by MsgType; bytes in / out
- Time since last message received (staleness), missed heartbeats, TestRequests sent
- ResendRequests sent / received, gap fills, sequence resets
- Session Rejects (3) and BusinessMessageRejects (j) sent / received

### Orders (business)

- Orders received, acked, rejected (by reason / validation rule), filled, partially filled, canceled, replaced
- Open orders by state
- **Orders waiting for trader action, and age of the oldest one** (key for manual ack)
- Time from order received to trader ack (p50 / p99)
- Fill quantity and notional per client / session
- Unknown-order messages (e.g. tag 41 not found), duplicate ClOrdIDs, PossDup messages

### Latency and pipeline

- Engine latency: FIX message in → response out, p50 / p99 / p99.9 / max (HdrHistogram)
- UI command round trip: click → ExecutionReport sent
- Ring buffer depth / utilisation
- Journal write latency; database writer lag (how far PostgreSQL is behind the journal)

### System

- Heap used, GC pause time and count, allocation rate (hot path should stay ≈ 0)
- CPU, thread count, journal disk free, DB connection pool usage
- Connected UI clients; log events dropped

### Alerts (shown in the UI, also via Prometheus Alertmanager)

- Session disconnected during its schedule
- Sequence gap / resend storm
- Order waiting for trader action longer than N seconds
- Engine p99 latency above target
- Database writer lag above N seconds
- Journal disk nearly full
