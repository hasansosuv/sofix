# SOFIX Coding, Documentation and Commit Standards (v2, 2026-10-10)

Goal (Roma, 2026-10-10): a new developer, or Roma looking from the engineering side, can understand **how each thing is implemented** without asking anyone: where it lives, how a message flows through it, why it was built that way, and how to test it. Every commit is **one small task**.

This file goes into the repository as `CONTRIBUTING.md`. `CLAUDE.md` points to it, and Claude Code must follow it like any developer. Where a tool can check a rule, the build enforces it (section 9).

---

## 1. Documentation map: where a reader finds what

| Question a reader has | Where the answer is |
|---|---|
| What is this system and how is it split up? | `README.md` (1 page) → `docs/architecture/overview.md` |
| How do I build, run and send my first order? | `docs/onboarding.md` |
| What was decided and why? | `docs/design/*.md` (design) and `docs/adr/NNNN-*.md` (one decision each) |
| How does feature X actually work in the code? | `docs/how-it-works/<feature>.md` |
| What does this module / package do? | `<module>/README.md`, `package-info.java` |
| What does this class / method do? | Javadoc (section 3) |
| What does this config property do? | `docs/reference/configuration.md` |
| What does error OEMS-XXX-NNNN mean, and what do I do? | `docs/reference/errors.md` |
| What does this FIX / trading word mean? | `docs/reference/glossary.md` |
| Production is broken, what now? | `docs/operations/runbook.md` |
| What changed in this version? | `CHANGELOG.md` (generated from commits) |

```
README.md
CONTRIBUTING.md                (this file)
CLAUDE.md
CHANGELOG.md
docs/
  onboarding.md
  architecture/overview.md     modules, threads, data flow, diagrams
  design/                      design docs (what and why, agreed with Roma)
  adr/                         0001-plain-quickfixj.md, 0002-single-writer-engine.md, …
  how-it-works/                inbound-order-flow.md, order-correlation.md, crash-recovery.md, …
  reference/                   configuration.md, errors.md, glossary.md, rest-api.md, database.md
  operations/runbook.md
  developer/                   generated audit docs (documentation-prompt.md); never hand-edited
<each module>/README.md
```

## 2. The four document types developers write

### 2.1 "How it works" pages (the most important one for understanding the code)

One page per feature, written **in the same commit series as the feature**. Template:

```markdown
# How it works: <feature>

## In one paragraph
What the feature does for the user, in plain words.

## Where it lives
| Piece | Class / file | Module |
|---|---|---|
| Entry point | InboundMessageGateway | oems-fix-qfj |
| ... | ... | ... |

## Flow
Mermaid sequence diagram of one real example, e.g. a 35=G with unknown tag 41,
from the QuickFIX/J callback to the OrderCancelReject on the wire and the rows written.

## Rules and edge cases
Numbered list, each rule with the class/method that implements it and the test that proves it.

## Configuration
Properties that change the behaviour, with defaults (link to reference/configuration.md).

## How to try it
Exact steps: config, FIX message to send (copy-paste ready), what you should see in the UI / DB / logs.

## Related
Design doc section, ADRs, other how-it-works pages.
```

### 2.2 Architecture Decision Records (ADR)

One short file per significant technical decision (library choice, threading model, storage format, a trade-off): **Context, Decision, Alternatives considered, Consequences, Status** (Proposed / Accepted / Superseded by NNNN). Never edited after acceptance; superseded by a new ADR. Design decisions already agreed with Roma (oems-design-v0.md section 15) are linked, not repeated.

### 2.3 Module README

Every Maven module has a `README.md`: purpose, what it may depend on and what it must not (the ArchUnit rule), main entry points, key classes in reading order ("start with X, then Y"), how to test only this module.

### 2.4 Reference pages

Kept in step with the code:
* `configuration.md`: every `sofix.*` property: meaning, type, default, allowed values, restart needed or live. **A commit that adds a property adds its row.**
* `errors.md`: every error code: meaning, likely cause, operator action. **A commit that adds an error code adds its row.**
* `glossary.md`: FIX and trading terms used in code (ClOrdID, LeavesQty, DFD, care order, street order…).
* `database.md`: tables and columns (generated from Flyway where possible) with a one-line meaning each.
* `rest-api.md`: generated from OpenAPI; each endpoint has a description and an example.

## 3. Code documentation

### 3.1 Every type (class, interface, enum, record)

```java
/**
 * Rejects a cancel or cancel/replace request whose OrigClOrdID (tag 41) does not belong
 * to any known order on this session and client.
 *
 * <p><b>Responsibility:</b> one step of the inbound pipeline for 35=F, 35=G and 35=AC.
 * Produces an OrderCancelReject (35=9) with CxlRejReason=1 (Unknown order).
 *
 * <p><b>How it fits in:</b>
 * <ul>
 *   <li>Called by {@link InboundPipeline} after {@link ClientResolver}, before {@link OrderStateGuard}.</li>
 *   <li>Reads {@link OrderIndex} (ClOrdID → orderKey) for the session and client.</li>
 *   <li>Returns a {@link CorrelationResult}; never sends FIX itself.</li>
 * </ul>
 *
 * <p><b>Threading:</b> order engine thread only; not thread-safe by design.
 * <p><b>Allocation:</b> hot path; allocation-free (reuses the pooled result).
 * <p><b>Design:</b> docs/design/order-lifecycle-and-persistence.md §3;
 *    docs/how-it-works/order-correlation.md
 */
```

Required sections: purpose (first sentence), responsibility, how it fits in (who calls it, what it calls, what it produces), threading, allocation (hot-path types), design link. Every package has `package-info.java` with the package's role and its main types in reading order.

### 3.2 Every method

* **Public / protected**: what it does; `@param` with units and allowed values; `@return`; `@throws` with when; **side effects** (sends FIX? writes journal? changes order state? publishes an event?).
* **Private**: at least one line saying what it does and why it exists.
* **Inline comments explain why**, not what: business reason, FIX rule with tag number, performance choice ("reused buffer, no allocation per message"), link to the design section for non-obvious rules.

### 3.3 Tests as documentation

* Test names are sentences: `rejectsCancelReplaceWithUnknownOrigClOrdId()`, `allowsSameClOrdIdOnTwoDifferentSessions()`.
* Structure `// given`, `// when`, `// then`.
* FIX acceptance tests contain the actual FIX messages (readable, `|` separated), so a test is also an example.
* Every rule listed in a how-it-works page has a test, and the page names it.

## 4. Naming

* Names say what a thing is or does, in trading / FIX vocabulary: `ExecutionReportBuilder`, `ClOrdIdUniquenessCheck`, `pendingTraderActionCount`.
* No abbreviations except standard FIX terms (`clOrdId`, `origClOrdId`, `execId`, `msgSeqNum`); no single-letter names outside short loops.
* No grab-bag classes (`Utils`, `Helper`, `Manager`, `Common`) unless the name says exactly what it manages.
* Booleans read as questions (`isLoggedOn`, `hasPendingReplace`); methods are verbs (`acceptOrder`, `rejectCancelRequest`); constants carry units (`HEARTBEAT_INTERVAL_SECONDS`).
* One concept, one name everywhere: the design doc, the class, the DB column and the UI use the same word (e.g. "client", never "customer" in one place and "company" in another).

## 5. Code structure (SOLID, readable, fast)

* One class, one responsibility; small methods (aim < 30 lines); no class over ~400 lines without a reason in its header.
* Depend on interfaces (ports) from `oems-application`; implementations are selected by configuration (`sofix.extensions.*`).
* Domain (`oems-domain`) is pure Java: no Spring, no QuickFIX/J, no database.
* Hot path is garbage-free: pooled objects, primitive collections, scaled-long prices, no streams / lambdas / boxing / string building per message; allocation tests guard it.
* No magic numbers or strings: FIX tags and values as named constants (`Tag.CL_ORD_ID = 11`).

## 6. Exception handling

Hierarchy (all unchecked, all with an error code and context):

```
OemsException (errorCode, context: sessionId, clientId, clOrdId, orderKey, msgSeqNum)
 ├─ FixMessageException          malformed / invalid FIX at business level
 ├─ OrderStateException          action not allowed in current order state
 ├─ SessionOperationException    start / stop / reset / seq-num operation failed
 ├─ ConfigurationException       invalid session / rule / config version
 └─ InfrastructureException      database, journal, network, disk
```

1. **Expected business outcomes are not exceptions**: a rejected order, an unknown 41, a limit breach are normal results (`ValidationResult`, `CommandResult`).
2. **Never swallow**: every `catch` handles (and logs at the right level) or rethrows wrapped with context and cause. Empty catch blocks fail the build.
3. **Catch at boundaries**: FIX adapter (log with raw message, BusinessMessageReject if appropriate, session stays up); engine thread top-level handler (log, flag order "needs attention", **engine thread never dies**); REST (one global handler → RFC 9457 problem details with errorCode and traceId); async DB writer (retry with backoff, alert, data stays in the journal).
4. **Stable error codes** (`OEMS-FIX-0012`, `OEMS-SES-0003`) in `docs/reference/errors.md`.
5. `try-with-resources` for every closeable; restore the interrupt flag; catch `Throwable` only in top-level thread handlers.
6. Validate at the boundary (FIX, REST), then trust inside the domain; `Objects.requireNonNull` with a message in constructors.

## 7. Logging for production debugging

Log4j2, async and garbage-free, ECS JSON.

| File | Content |
|---|---|
| `oems-app.log` | Everything INFO and above |
| `oems-error.log` | WARN and ERROR with stack traces: the first file in an incident |
| `fix-session-<sessionId>.log` | Connect, logon, logout, resend, gap fill, seq-num changes, rejects |
| `fix-messages-<sessionId>.log` | Raw FIX, off by default, switchable per session at runtime |
| `oems-audit.log` | Operator and trader actions, config changes |
| `oems-perf.log` | Latency and throughput summaries |

* ERROR = needs a human, always with an error code; WARN = unexpected but handled; INFO = lifecycle and every order state change (one line); DEBUG/TRACE off by default, switchable at runtime per package or session.
* Every line carries `traceId`, `sessionId`, `clientId`, `clOrdId`, `orderKey` when known.
* Never log secrets: tags 554 and 925 are masked everywhere.
* Startup banner: version, git commit, config version, active implementation of every extension point.

## 8. Commits: one small task each

### 8.1 What "one small task" means

A commit does **one thing a reviewer can describe in one sentence** without "and". It:
* builds and passes `./mvnw verify` on its own (every commit, not just the last one);
* contains the code, its tests, and the docs it makes out of date (how-it-works page, configuration / errors rows, Javadoc);
* is small: aim for under ~300 changed lines excluding generated files and tests; if it is bigger, ask whether it can be split;
* never mixes kinds: no refactor + feature, no formatting + logic, no dependency upgrade + feature, no two unrelated fixes.

### 8.2 How a feature is split (example: "reject G/F with unknown tag 41")

```
1. feat(domain): add OrderIndex for ClOrdID → orderKey per session and client
2. test(domain): cover ClOrdID uniqueness per session and per hub client
3. feat(application): add OrigClOrdIdCorrelator step to the inbound pipeline
4. feat(fix): send OrderCancelReject 102=1 for unknown OrigClOrdID
5. test(acceptance): FIX test for G and F with unknown 41
6. docs(how-it-works): order-correlation.md with flow and rules
```

(Steps 1 and 2 may be one commit; tests normally go with their code. Docs may go with the last code commit if small.)

### 8.3 Commit message format (Conventional Commits)

```
<type>(<scope>): <what, imperative, max 72 chars>

What: one or two sentences on what changed.
Why: the reason / requirement (design doc section, issue, Roma's decision).
How it works: the key classes touched and how they interact (2-5 lines).
How to test:
  - automated: which tests (class names), test level (see 8.4)
  - manual: steps / FIX message to send / what to expect, or "n/a"
Docs: files updated, or "none needed because …"
Design: docs/design/<file>.md §<n>
```

Types: `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `build`, `chore`. Scopes are module or area names: `domain`, `application`, `fix`, `persistence`, `api`, `app`, `session`, `orders`, `jobs`.

Provide this template as `.gitmessage` and set `git config commit.template .gitmessage`.

### 8.4 Test levels (named in every commit)

| Level | What it proves | Example |
|---|---|---|
| Unit | One class's logic | OrderIndex, fill roll-up math |
| Component | Several classes inside one module, no network | Inbound pipeline with in-memory adapters |
| FIX acceptance | Real FIX over localhost with a QuickFIX/J test counterparty | D → ack → fill; G with unknown 41 |
| Integration | Real PostgreSQL / journal (Testcontainers) | Messages land in `fix_message`, recovery reload |
| Recovery | Kill and restart | kill -9 during a burst, state and seq nums match |
| Performance | Latency / allocation budget | No allocation per message on the hot path |

### 8.5 Branches and pull requests

* One feature branch per layer or feature (`feat/order-lifecycle`), made of small commits.
* Before starting, list the planned commits (as in 8.2) and agree them.
* Merge with rebase or a merge commit, **never squash**: the small commits are the documentation of how the feature was built.
* PR description: What changed / Why / How it works / How to test (per test level) / Performance impact / Docs updated / Design links.

## 9. Enforced by the build

Spotless (formatting), Checkstyle (naming, Javadoc on every type and method, no empty catch, package-info present), SpotBugs + Error Prone, ArchUnit (module boundaries, QuickFIX/J only in `oems-fix-qfj`, domain without Spring), JaCoCo (coverage threshold on domain and application), allocation tests, commitlint on commit messages (type, scope, required "How to test" section), a docs check (every `sofix.*` property in `configuration.md`, every error code in `errors.md`).

## 10. Rules for Claude Code in this repository

1. Before coding a task, list the planned commits (8.2) and wait for OK.
2. Make one commit at a time; run `./mvnw verify` before each; never batch several tasks into one commit.
3. Each commit message follows 8.3 exactly.
4. Update the how-it-works page, reference rows and Javadoc in the same commit series; never leave docs for "later".
5. At the end, show the commit list with, for each commit, what to test.
6. Ask before deleting files or changing an agreed decision.


# <type>(<scope>): <what, imperative, max 72 chars>
# types: feat fix perf refactor test docs build chore
# scopes: domain application fix persistence api app session orders jobs

What:
Why:
How it works:
How to test:
  - automated:  (test classes; level: unit / component / FIX acceptance / integration / recovery / performance)
  - manual:
Docs:
Design: docs/design/

