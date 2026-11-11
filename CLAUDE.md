# SOFIX workspace

Three repositories, each with its own git history. Commit in the repository you changed.

- `sofix-ui-fe/`: Angular app (the UI).
- `sofix-ui-be/`: Node.js backend (BFF): users, companies (buy side), access, layouts; forwards to the OEMS. Port 8090.
- `sofix-oems/` (sofix-oems): Spring Boot + QuickFIX/J FIX engine: FIX sessions, sell-side order handling, buy-side order entry, certification (specifications, test suites, certification mode). Orders are kept in memory only for now.

This folder is a git repository too, for the files shared by all three: this `CLAUDE.md`, `CONTRIBUTING.md`, `compose.yaml` (+ `compose.db-ui.yaml`, `.env.example`, `docker/`), the design docs in `docs/design/`, the end-to-end feature pages in `docs/features/` and the deployment guides in `docs/deployment/`. It ignores the three repositories (`.gitignore`); commit changes to those files here. (The Mock Engine, `sofix-mock-backend`, was retired on 2026-10-12.)

`compose.yaml` (in this folder) is the one Docker Compose file: `docker compose up -d --build` here builds and runs the app (ui, :8080), the backend (:8090), the OEMS (:8095, FIX 9870-9899) and one PostgreSQL server with both databases (:5433). Every setting is in `.env.example`; `docs/deployment/docker.md` explains them. `DEPLOYMENT_MODE` chooses the side; a second stack runs the other side (`docs/deployment/local-buy-side.md`).

## Where to read

- What exists, feature by feature, across the three repositories: `docs/features/<feature>.md` (flow, data, where each rule is enforced and tested, known limitations). Start with `deployment-modes.md`.
- The FIX engine: `sofix-oems/docs/developer/00-DEVELOPER-DOCUMENTATION-INDEX.md` (start with `01-SYSTEM-OVERVIEW.md`); rules per feature in `sofix-oems/docs/how-it-works/`; risks in `ARCHITECTURE-FINDINGS.md`; design vs code in `DESIGN-VS-IMPLEMENTATION-GAPS.md`.
- The app: `sofix-ui-fe/docs/developer/` (testing workflow: `22-TESTING-WORKFLOW.md`; test case storage: `test-case-storage.md`).
- Running and updating the stack: `docs/deployment/`.
- What was intended (not all of it is built): `docs/design/`.

## Rules for every repository

- Never start or stop the services Ahmed runs (the Docker stack: ui 8080, backend 8090, OEMS 8095, PostgreSQL 5433; the Angular dev server). He runs them to read their logs. Throwaway instances on other ports are fine for checks; always remove them afterwards.
- After a change, build only (e.g. `npx ng build --configuration development`, `./mvnw -q -DskipTests compile`). Run tests only when asked, narrowed to what changed.
- Small, focused commits, one concern each, in the repository that changed.
- Errors are reported to the notification bell and the Error Log, never shown inline in a panel.

## sofix-oems

### What this is

**sofix-oems** is the FIX engine service of the SOFIX platform: a FIX Order and Execution Management System that acts as a broker (sell side: receives orders, sends ExecutionReports) or as a buy side (sends orders, receives ExecutionReports), and runs FIX certification test cases between the two.

The platform has three parts:

- **sofix-ui**: Angular application.
- **UI backend (BFF)**: Node.js. Owns users, roles, permissions, groups, companies and layouts; authenticates users; the only caller of sofix-oems (except a sell-side OEMS posting certification results to a buy-side OEMS).
- **sofix-oems**: Spring Boot + QuickFIX/J. Owns FIX sessions, orders, messages, test cases, ATDL files, test results, templates, rules and reference data. Talks to external FIX counterparties.

Current phase: build the **outline** (every component as an interface with a default implementation and placeholders), then fill it in layer by layer, broker side first. Built so far: sessions, sell-side orders (attribution, manual/auto, ER templates, certification mode), buy-side order entry and templates, test suites. Next in the order lifecycle plan: storing orders and messages (`docs/design/order-lifecycle-and-persistence.md`, Phase D).

### Design docs (in `docs/design/`)

- `oems-design-v0.md`: overall design; decisions log in section 15
- `skeleton-outline.md`: the outline: every extension point, its default and placeholder implementations, and the layer plan
- `components-and-data-ownership.md`: who talks to whom; UI vs engine databases; private/group/public data
- `application-scope-and-tenancy.md`: one owner, clients, dedicated vs hub sessions, order visibility; deployment modes and buy-side companies (section 7)
- `session-configuration.md`: FIX settings vs business settings per session
- `environment-and-promotion.md`: UAT / PROD and config promotion
- `test-routing-by-user-tag.md`: UAT/PROD, run-test-cases toggle, user resolution by tag + aliases
- `routing-inbound-order-to-user.md`: who an inbound order belongs to
- `execution-report-templates.md`: ER templates, manual/auto per action, per asset class
- `buy-side-message-templates.md`: outbound order templates per asset class and session
- `test-case-certification.md`: test suites, certification mode, results posted to the buy side
- `order-hierarchy.md`: parent / child orders
- `order-lifecycle-and-persistence.md`: id tags per message type, correlation, busts/corrections, storage, persistence by TIF, crash recovery (in phases A–G)
- `order-validation-rules.md`: configurable business validation rule sets
- `database-tables.md`: all tables of the `ui` and `oems` databases
- `observability.md`: metrics, logs, traces, alerts
- `mock-engine-migration.md`: moving the Mock Engine's work into sofix-oems (done)
- Coding standards: `CONTRIBUTING.md` in this folder and `sofix-oems/CONTRIBUTING.md` (must be followed for all code)

### Agreed decisions (do not change without asking Ahmed)

Where today's code differs from these decisions (e.g. SSE instead of WebSocket, headers instead of a signed token, orders in memory, one lock instead of a single-writer engine, Broker Settings rules for attribution) is listed in `sofix-oems/docs/developer/DESIGN-VS-IMPLEMENTATION-GAPS.md`.

**Stack**

- Java 25 LTS. Maven multi-module with the Maven wrapper (`./mvnw`).
- Plain QuickFIX/J (`org.quickfixj`), **no** quickfixj-spring-boot-starter. QFJ version pinned once in the parent POM.
- Only the `oems-fix-qfj` module may import `quickfix.*` (enforced by ArchUnit).

**Architecture**

- The browser never calls sofix-oems. Node BFF → sofix-oems over REST (commands/queries) + one WebSocket event stream (engine → BFF).
- Every BFF call carries a signed token with the user's id, groups and roles; sofix-oems verifies it and enforces data visibility itself.
- One PostgreSQL server, **two databases**: `ui` (owned by the Node BFF; named `sofix` by default, `UI_DB_NAME`) and `oems` (owned by sofix-oems). Each service only touches its own database; no cross-database queries or foreign keys. sofix-oems stores user ids only, never user details.
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

**Deployment mode and buy side (2026-10-12)**

- One codebase, two deployments: `sofix.deployment.mode: SELL_SIDE | BUY_SIDE` (compose `DEPLOYMENT_MODE`), each with its own databases. Code is separated by package / folder: `common`, `sellside` (`sell-side`), `buyside` (`buy-side`); only the active side is wired.
- BUY_SIDE has customer companies with users, all in one shared database: `company_id` on every buy-side record, filtered first; platform admin creates companies, company admin manages its users; visibility own (default) or company. SELL_SIDE stays single-owner (below).
- Test case certification between the two: `docs/design/test-case-certification.md` (match by strategy tag + 38 in the user's active suite; FIX answer + JSON result posted to the buy side).

**Clients, users and orders (2026-10-10)**

- One application owner (a broker); all users belong to the owner. "Companies" are **clients** (buy-side firms, records only, no login). No multi-tenancy, and no `tenant_id` (dropped 2026-10-12).
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

### Modules (in `sofix-oems/`)

Inside each module, packages are split `common` / `sellside` / `buyside` (ArchUnit keeps the sides apart).

- `oems-domain`: pure Java; sell and buy order models and rules, sessions, templates, certification, validation logic. No Spring, no QuickFIX/J.
- `oems-application`: use cases + port interfaces (the extension points).
- `oems-fix-qfj`: QuickFIX/J adapter, session management.
- `oems-persistence`: PostgreSQL repositories, Flyway migrations, stored broker specifications (the journal is not built yet).
- `oems-api`: REST controllers + the SSE event stream for the Node BFF.
- `oems-app`: Spring Boot main, wiring, configuration, log4j2 config.

### How to work (in `sofix-oems/`)

- Build and test: `./mvnw verify` must pass before every commit (formatting, Checkstyle, SpotBugs, ArchUnit, tests).
- Database tests use Testcontainers (Docker must be running). Local DB: `docker compose up -d postgres db-init` in this folder (PostgreSQL on 5433). The observability stack (`ops/observability/`) is not built yet.
- Conventional Commits (`feat:`, `fix:`, `perf:`, `refactor:`, `test:`, `docs:`); the commit body says what changed, why, and how to test.
- Small, focused commits, directly on `main` for now (no feature branches unless Ahmed asks). Ask before deleting files or changing an agreed decision.
- A feature also updates its `sofix-oems/docs/how-it-works/` page, its `docs/features/` page here, and the affected `sofix-oems/docs/developer/` pages (bump their "Verified against commit" line).
