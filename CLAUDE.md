# CLAUDE.md: sofix-oems

Instructions for Claude Code working in this repository. Read this first, then the docs it points to.

## What this is
**sofix-oems** is the FIX engine service of the SOFIX platform: a FIX Order and Execution Management System that acts as a broker (sell side: receives orders, sends ExecutionReports) and later as a buy side (sends orders, receives ExecutionReports), and runs FIX certification test cases on UAT sessions.

The platform has three parts:
- **sofix-ui**: Angular application.
- **UI backend (BFF)**: Node.js. Owns users, roles, permissions, groups and layouts; authenticates users; the only caller of sofix-oems.
- **sofix-oems** (this repo): Spring Boot + QuickFIX/J. Owns FIX sessions, orders, messages, test cases, ATDL files, test results, templates, rules and reference data. Talks to external FIX counterparties.

Current phase: build the **outline** (every component as an interface with a default implementation and placeholders), then fill it in layer by layer, broker side first.

## Design docs (in `docs/design/`)
- `oems-design-v0.md`: overall design; decisions log in section 15
- `skeleton-outline.md`: the outline: every extension point, its default and placeholder implementations, and the layer plan
- `components-and-data-ownership.md`: who talks to whom; UI vs engine databases; private/group/public data
- `test-routing-by-user-tag.md`: UAT/PROD, run-test-cases toggle, user resolution by tag + aliases
- `execution-report-templates.md`: ER templates, manual/auto per action, per asset class
- `order-validation-rules.md`: configurable business validation rule sets
- `observability.md`: metrics, logs, traces, alerts
- `starter-vs-plain-quickfixj.md`: why no QuickFIX/J Spring Boot starter
- `application-scope-and-tenancy.md`: one owner, all users are the owner's; companies are clients; dedicated vs hub (NYFIX/Autex) sessions; order visibility; buy-side SaaS (proposed, section 7)
- `session-configuration.md`: FIX settings vs business settings per session
- `environments-and-promotion.md`: UAT / PROD and config promotion
- `buy-side-message-templates.md`: outbound order templates (buy side, later)
- `order-hierarchy.md`: parent / child orders
- `order-lifecycle-and-persistence.md`: id tags per message type, correlation, busts/corrections, storage, persistence by TIF, crash recovery
- `database-tables.md`: all tables of the `ui` and `oems` databases
- Coding standards: `CONTRIBUTING.md` (must be followed for all code)

## Agreed decisions (do not change without asking Roma)

**Stack**
- Java 25 LTS. Maven multi-module with the Maven wrapper (`./mvnw`).
- Plain QuickFIX/J (`org.quickfixj`), **no** quickfixj-spring-boot-starter. QFJ version pinned once in the parent POM.
- Only the `oems-fix-qfj` module may import `quickfix.*` (enforced by ArchUnit).

**Architecture**
- The browser never calls sofix-oems. Node BFF → sofix-oems over REST (commands/queries) + one WebSocket event stream (engine → BFF).
- Every BFF call carries a signed token with the user's id, groups and roles; sofix-oems verifies it and enforces data visibility itself.
- One PostgreSQL server, **two databases**: `ui` (owned by the Node BFF) and `oems` (owned by sofix-oems). Each service only touches its own database; no cross-database queries or foreign keys. sofix-oems stores user ids only, never user details.
- User-owned records (test cases, suites, runs, ATDL specs) carry `owner_user_id` + `visibility` (PRIVATE / GROUP / PUBLIC).

**Sessions**
- Every FIX session has a `role` (SELL_SIDE / BUY_SIDE), a `connectionType` (ACCEPTOR / INITIATOR) and an `environment` (UAT / PROD), all independent.
- Sessions are created, started, stopped, and have sequence numbers set/reset at runtime, without restarting the app.
- Manual vs auto handling is configured **per action** (ack, reject, fill, cancel, replace, done for day, expire) and is independent of testing.
- UAT sessions only: a "Run test cases" toggle. PROD sessions never run tests.
- Inbound messages are attributed to a user: order chain first, then a configurable list of tags per session (primary 116, alternatives e.g. 57, 50), looked up in the alias table (`user_identity_alias`, one alias → one user). No match in auto mode → ER rejected (39=8) with 58 "User details missing". Tests run only for a logged-in user; the order still shows on that user's blotter.

**Build approach (outline first)**
- Every step of the order flow and every business/platform capability is an **interface** with a working **default implementation** and documented **placeholders** (see `skeleton-outline.md`).
- The active implementation is chosen by configuration (`sofix.extensions.*`, `sofix.action-mode.*`, `sofix.jobs.*`) via `@ConditionalOnProperty`; adding a feature = new class + config value, never a rewrite. The app logs every active implementation at startup.
- Scheduled jobs (Done for Day, Expire, …) and all UI/automated actions submit commands into the engine's ring buffer and go through the same path as a trader click (ActionModeResolver, state machine, ER builder, journal, audit).
- Buy side (order entry D/AB/F/G, ER processing, allocations J/P/AS) and business services (positions, P&L, risk limits + kill switch, reports, drop copy, trade export, …) exist as placeholders now and are built as later layers.

**Clients, users and orders (2026-10-10)**
- One application owner (a broker); all users belong to the owner. "Companies" are **clients** (buy-side firms, records only, no login). No multi-tenancy on the broker side, but every `oems` table has a `tenant_id` with one fixed value.
- Client of an inbound order: from the session (DEDICATED) or from tag 115 via `client_hub_identity` (HUB sessions such as NYFIX/Autex). Cancels/replaces must match the original order's client.
- ClOrdID is unique per (session, client), never across sessions. Id / reference tags are configurable per message type (`message_key_config`, default 11 / 41 / 37 / 17 / 19). Unknown 41 → OrderCancelReject 102=1.
- We assign 37 (OrderID) once per order. Busts/corrections link 19 → 17.
- One model for parent/child: any client order can get MANUAL or STREET children and is a parent once it has one; direct fills on the client order stay possible.
- Manual vs auto is resolved per action in this order: ops kill switch → admin lock → the order's user's own setting → session override → profile default.
- Every change to an order writes an `order_event` with actor CLIENT / TRADER / AUTO / BROKER / SYSTEM. Client-side and street-side messages share the `fix_message` table (columns side, direction, root_order_id).
- Order state by TIF: DAY orders close at end of day; GTC/GTD are carried over until filled, cancelled or expired. A user never silently deletes a live order; closing it sends the client an ER.
- Crash safety: nothing is acknowledged before it is in the journal; on restart, load live orders, replay the journal tail, rebuild indexes, then start FIX sessions.

**Data, config, performance**
- Config (sessions, profiles, rules, templates, reference data) lives in PostgreSQL, versioned; held in memory by the engine, never read on the hot path. Until the persistence layer, defaults come from `application.yml`.
- Every inbound/outbound FIX message is stored: local journal first, then batched asynchronously into PostgreSQL. Retention 1 year.
- No routing rules in the broker phase. Config-in-Git comes later.
- Garbage-free hot path in our own code (pooled objects, primitive collections, scaled-long prices, single-writer order engine thread).

**Logging and observability**
- Log4j2 (async + garbage-free), Logback excluded. JSON logs in ECS format. Files: oems-app.log, oems-error.log, per-session logs, oems-audit.log, oems-perf.log. Every line carries traceId, sessionId, clOrdId, orderKey (when known).
- Metrics: Micrometer → Prometheus (`/actuator/prometheus`) from day 1; low-cardinality labels only (never order ids). Grafana, Alertmanager, Filebeat → Elasticsearch/Kibana and OpenTelemetry → Tempo; configs as code in `ops/observability/`.

## Modules
- `oems-domain`: pure Java; order model, state machine, validation logic. No Spring, no QuickFIX/J.
- `oems-application`: use cases + port interfaces (the extension points).
- `oems-fix-qfj`: QuickFIX/J adapter, session management.
- `oems-persistence`: journal + PostgreSQL.
- `oems-api`: REST + WebSocket adapters for the Node BFF.
- `oems-app`: Spring Boot main, wiring, configuration, log4j2 config.

## How to work
- Follow `CONTRIBUTING.md` (coding, documentation and commit standard v2). In short:
  - Before a task, list the planned commits and wait for OK. **One small task per commit**, each one passing `./mvnw verify` on its own; never mix a refactor, formatting or upgrade with a feature.
  - Commit message: Conventional Commits title, then What / Why / How it works / How to test (test level) / Docs / Design sections (template in `.gitmessage`).
  - Each feature gets a `docs/how-it-works/<feature>.md` page (flow diagram, rules with the class and test that implement them, how to try it), written in the same commit series. New config properties and error codes get their rows in `docs/reference/`.
  - Every class, interface and method has Javadoc (purpose, how it fits in, threading, allocation, design link); every package has `package-info.java`; every module has a README.
- Database tests use Testcontainers (Docker must be running). Local DB: `docker compose up -d`; observability stack: `docker compose --profile observability up -d`.
- Branch per feature; merge without squashing. Ask before deleting files or changing an agreed decision.
