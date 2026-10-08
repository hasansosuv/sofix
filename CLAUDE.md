# SOFIX workspace

Four repositories, each with its own git history. Commit in the repository you changed.

- `sofix-ui-fe/`: Angular app (the UI).
- `sofix-ui-be/`: Node.js backend (BFF): users, access, layouts; forwards to the engines. Port 8090.
- `sofix-mock-backend/`: the Mock Engine (Node.js, port 8091): orders, certification test case generation, test runs, mock SSO. It is being moved into `sofix-oems`; see `docs/design/mock-engine-migration.md`.
- `sofix-oems/` (sofix-oems): Spring Boot + QuickFIX/J FIX engine: FIX sessions today, later orders, test cases and results.

This folder is a git repository too, for the files shared by all four: this `CLAUDE.md`, `compose.yaml` and the design docs in `docs/design/`. It ignores the four repositories (`.gitignore`); commit changes to those files here.

`compose.yaml` (in this folder) is the one Docker Compose file: `docker compose up -d` here runs the backend, the Mock Engine, the app database (PostgreSQL :5433) and the OEMS database (:5434). The OEMS itself runs on the host (port 8095).

The app's developer docs are in `sofix-ui-fe/docs/developer/` (testing workflow: `22-TESTING-WORKFLOW.md`; test case storage: `test-case-storage.md`).

## Rules for every repository

- Never start or stop the services Ahmed runs (backend 8090, Mock Engine 8091, the OEMS, the Angular dev server, Docker). He runs them to read their logs. Throwaway instances on other ports are fine for checks; always remove them afterwards.
- After a change, build only (e.g. `npx ng build --configuration development`, `./mvnw -q -DskipTests compile`). Run tests only when asked, narrowed to what changed.
- Small, focused commits, one concern each, in the repository that changed.
- Errors are reported to the notification bell and the Error Log, never shown inline in a panel.

## sofix-oems

### What this is

**sofix-oems** is the FIX engine service of the SOFIX platform: a FIX Order and Execution Management System that acts as a broker (sell side: receives orders, sends ExecutionReports) and later as a buy side (sends orders, receives ExecutionReports), and runs FIX certification test cases on UAT sessions.

The platform has three parts:

- **sofix-ui**: Angular application.
- **UI backend (BFF)**: Node.js. Owns users, roles, permissions, groups and layouts; authenticates users; the only caller of sofix-oems.
- **sofix-oems**: Spring Boot + QuickFIX/J. Owns FIX sessions, orders, messages, test cases, ATDL files, test results, templates, rules and reference data. Talks to external FIX counterparties.

Current phase: build the **outline** (every component as an interface with a default implementation and placeholders), then fill it in layer by layer, broker side first.

### Design docs (in `docs/design/`)

- `oems-design-v0.md`: overall design; decisions log in section 15
- `skeleton-outline.md`: the outline: every extension point, its default and placeholder implementations, and the layer plan
- `components-and-data-ownership.md`: who talks to whom; UI vs engine databases; private/group/public data
- `test-routing-by-user-tag.md`: UAT/PROD, run-test-cases toggle, user resolution by tag + aliases
- `execution-report-templates.md`: ER templates, manual/auto per action, per asset class
- `order-validation-rules.md`: configurable business validation rule sets
- `observability.md`: metrics, logs, traces, alerts
- Coding standards: `sofix-oems/CONTRIBUTING.md` (must be followed for all code)

### Agreed decisions (do not change without asking Ahmed)

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

- Every step of the order flow and every business/platform capability is an **interface** with a working **default implementation** and documented **placeholders** (see `docs/design/skeleton-outline.md`).
- The active implementation is chosen by configuration (`sofix.extensions.*`, `sofix.action-mode.*`, `sofix.jobs.*`) via `@ConditionalOnProperty`; adding a feature = new class + config value, never a rewrite. The app logs every active implementation at startup.
- Scheduled jobs (Done for Day, Expire, …) and all UI/automated actions submit commands into the engine's ring buffer and go through the same path as a trader click (ActionModeResolver, state machine, ER builder, journal, audit).
- Buy side (order entry D/AB/F/G, ER processing, allocations J/P/AS) and business services (positions, P&L, risk limits + kill switch, reports, drop copy, trade export, …) exist as placeholders now and are built as later layers.

**Data, config, performance**

- Config (sessions, profiles, rules, templates, reference data) lives in PostgreSQL, versioned; held in memory by the engine, never read on the hot path. Until the persistence layer, defaults come from `application.yml`.
- Every inbound/outbound FIX message is stored: local journal first, then batched asynchronously into PostgreSQL. Retention 1 year.
- No routing rules in the broker phase. Config-in-Git comes later.
- Garbage-free hot path in our own code (pooled objects, primitive collections, scaled-long prices, single-writer order engine thread).

**Logging and observability**

- Log4j2 (async + garbage-free), Logback excluded. JSON logs in ECS format. Files: oems-app.log, oems-error.log, per-session logs, oems-audit.log, oems-perf.log. Every line carries traceId, sessionId, clOrdId, orderKey (when known).
- Metrics: Micrometer → Prometheus (`/actuator/prometheus`) from day 1; low-cardinality labels only (never order ids). Grafana, Alertmanager, Filebeat → Elasticsearch/Kibana and OpenTelemetry → Tempo; configs as code in `ops/observability/`.

### Modules (in `sofix-oems/`)

- `oems-domain`: pure Java; order model, state machine, validation logic. No Spring, no QuickFIX/J.
- `oems-application`: use cases + port interfaces (the extension points).
- `oems-fix-qfj`: QuickFIX/J adapter, session management.
- `oems-persistence`: journal + PostgreSQL.
- `oems-api`: REST + WebSocket adapters for the Node BFF.
- `oems-app`: Spring Boot main, wiring, configuration, log4j2 config.

### How to work (in `sofix-oems/`)

- Build and test: `./mvnw verify` must pass before every commit (formatting, Checkstyle, SpotBugs, ArchUnit, tests).
- Database tests use Testcontainers (Docker must be running). Local DB: `docker compose up -d oems-postgres` in this folder; observability stack: `docker compose --profile observability up -d`.
- Conventional Commits (`feat:`, `fix:`, `perf:`, `refactor:`, `test:`, `docs:`); the commit body says what changed, why, and how to test.
- Small, focused commits on a feature branch. Ask before deleting files or changing an agreed decision.
