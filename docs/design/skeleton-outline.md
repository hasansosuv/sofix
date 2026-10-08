# sofix-oems: the outline ("painting" approach), draft 2026-10-08

Ahmed's approach (2026-10-08): first draw the whole outline: every component the system will have, as interfaces with a **default (simple) implementation** and **empty placeholder classes** for features that come later. Then fill it in layer by layer. Everything is configurable and extensible: switching from the default to the real implementation is a configuration change, not a rewrite.

Example from Ahmed: message templates are not built yet, so the engine sends default Ack / Fill reports; but the manual-mode class already exists (empty), and the check "is this action manual or auto?" already runs for every message.

---

## 1. How the extension points work

- Every component the order flow uses is an **interface (port)** in `oems-application` (or `oems-domain` for pure logic).
- Each interface has a **default implementation** that works today, and possibly **placeholder implementations** that exist, compile, are documented, and either do nothing or throw `NotImplementedYetException` with a clear message.
- Which implementation is active is chosen by configuration:

```yaml
sofix:
  extensions:
    execution-report-builder: default # later: template
    business-validator: basic # later: rules
    user-resolver: none # later: tag-alias
    test-case-executor: none # later: uat
  action-mode: # per action; later from broker profile in DB
    ack: AUTO
    fill: AUTO
    cancel: AUTO
    replace: AUTO
    reject-invalid: AUTO
```

- Implementation: Spring `@ConditionalOnProperty` per implementation (or a small `ExtensionRegistry` keyed by name). Adding a new implementation = new class + new config value; nothing else changes (Open/Closed).
- At startup the app logs which implementation is active for every extension point, so it is always clear what is running.

## 2. Inbound order pipeline (sell side)

Each step is one interface. Arrow = calls in order, all on the single order-engine thread.

```
FIX message in (QuickFIX/J Application)
  → InboundMessageGateway          hands message to engine ring buffer
  → MessageJournal                 records raw message
  → UserResolver                   who does this belong to?
  → FixLevelValidator              dictionary / structure
  → OrderCorrelator                find order chain (11 / 41 / 37)
  → OrderStateGuard                is this message allowed in the current state?
  → BusinessValidator              business rules
  → TestCaseExecutor               (UAT + toggle on only)
  → ActionModeResolver             MANUAL or AUTO for the next action?
       ├─ AUTO   → AutoActionHandler   decides the response (ack, fill…)
       └─ MANUAL → ManualActionHandler queue for trader in UI
  → OrderStateMachine              apply transition
  → ExecutionReportBuilder         build ER / CancelReject
  → OutboundMessageGateway         send via QuickFIX/J
  → OrderRepository                save state
  → OrderEventPublisher            notify BFF / UI
  → MetricsRecorder                count / time it
```

## 2b. Outbound order pipeline (buy side), outline only

Same engine, same order model and state machine, with the direction reversed: we send orders and receive ExecutionReports. Session `role` = BUY_SIDE (acceptor or initiator).

```
UI / API command (new order, cancel, replace, allocate)
  → OrderEntryService              accept command from BFF (user, session, order fields)
  → PreTradeValidator              same rule engine as sell side, buy-side rule set
  → OutboundOrderBuilder           build 35=D / AB / F / G / AC (per FIX version, later templates)
  → OrderStateMachine              PendingNew / PendingCancel / PendingReplace
  → OutboundMessageGateway         send via QuickFIX/J
  ... counterparty responds ...
  → InboundMessageGateway → ExecutionReportProcessor  apply 35=8 / 35=9 to the order (fills, cancels, rejects; dedup by ExecID; busts/corrections)
  → OrderEventPublisher            update blotter
  → AllocationService              35=J AllocationInstruction out, 35=P AllocationInstructionAck / 35=AS AllocationReport in
```

## 2c. Business and platform capabilities (placeholders in the outline)

What a full OEMS has beyond order handling. Each is an interface with a default (simple or no-op) implementation now, so it can be built later without reshaping the engine. Fills, cancels and EOD jobs already publish events these services listen to.

### Business

| Interface              | Purpose                                                                                                                     | Default in outline                            | Later                                                     |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- | --------------------------------------------------------- |
| `PositionKeeper`       | Intraday positions per account / symbol / session, updated from every fill (both sides)                                     | In-memory, computed from fills                | Persisted, start-of-day positions loaded, position limits |
| `PnlCalculator`        | Realized and unrealized P&L per account / symbol / trader                                                                   | **placeholder** (returns zero)                | Uses positions + market prices, FIFO/average cost         |
| `MarketDataProvider`   | Last / close / reference prices (price collars, P&L, auto-fill price)                                                       | Static prices from config / CSV               | Live market data feed                                     |
| `RiskLimitChecker`     | Stateful pre-trade risk: daily notional, open-order count, position limits, fat-finger, per-account **kill switch**         | **placeholder** (allow all)                   | Real limits from reference data; kill switch from UI      |
| `CommissionCalculator` | Commission and fees on fills (tags 12/13, 136 MiscFees)                                                                     | **placeholder** (none)                        | Rate cards per client / asset class                       |
| `DropCopyPublisher`    | Copy of every ExecutionReport to a drop-copy session (risk / back office)                                                   | **placeholder** (off)                         | Drop-copy FIX sessions                                    |
| `TradeExportService`   | Send booked trades to back office / clearing (CSV, FIX, API)                                                                | **placeholder**                               | Scheduled EOD export                                      |
| `ReportService`        | Reports: EOD trades, fills, order audit, session activity, rejects by rule, test results; CSV / PDF; on demand or scheduled | **placeholder** (interface + report registry) | Report screens + scheduled reports via JobScheduler       |
| `RegulatoryReporter`   | Regulatory transaction / order reporting (e.g. CAT, MiFID II) from the audit trail                                          | **placeholder**                               | Per regime, as needed                                     |
| `TradingCalendar`      | Trading days, holidays, market hours per exchange / session                                                                 | Weekdays, hours from config                   | Holiday calendars per market                              |
| `OrderCarryOverJob`    | Carry GTC / GTD orders over to the next trading day                                                                         | **placeholder** job, disabled                 | Enabled with persistence layer                            |
| `SymbologyMapper`      | Map symbols between counterparties (ticker, RIC, ISIN, CUSIP)                                                               | Identity mapping                              | Mapping tables per session                                |
| `NotificationService`  | Email / Slack / Teams notifications for business events (session down, large order, test run finished)                      | Log only                                      | Channels configured in UI                                 |

### Platform

| Interface                                      | Purpose                                                                                    | Default in outline                    | Later                                    |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------ | ------------------------------------- | ---------------------------------------- |
| `IdGenerator`                                  | OrderID (37), ExecID (17) and `$unique`-style ids, unique per session/day, allocation-free | Time + counter based                  | Same, persisted counters across restarts |
| `TimeProvider`                                 | Single source of time (testable, can be frozen in tests and simulations)                   | System clock                          | n/a                                      |
| `SecurityContextProvider`                      | Verify the BFF's signed token: user id, groups, roles on every API call                    | **placeholder** (local "system" user) | JWT verification + permissions           |
| `ConfigRepository` / `ConfigActivationService` | Versioned config (profiles, rules, templates, sessions) and atomic activation              | From `application.yml`                | PostgreSQL, versioned, UI-edited         |
| `RecoveryService`                              | On startup: replay journal, rebuild order state, reconcile sequence numbers                | **placeholder** (fresh start)         | Journal replay with persistence layer    |
| `MessageThrottle`                              | Per-session inbound rate limit (protects the engine from a runaway client)                 | **placeholder** (unlimited)           | Configurable per session                 |
| `IntegrationEventPublisher`                    | Publish business events to other systems (Kafka etc.) via an outbox                        | **placeholder** (off)                 | Kafka / other bus if needed              |
| `ClusterCoordinator`                           | Which instance is active (HA failover)                                                     | Single instance, always active        | Active/passive leadership                |
| `DataRetentionJob` / `ArchiveService`          | Drop / archive data older than 1 year                                                      | **placeholder** job, disabled         | Enabled with persistence layer           |

## 3. Extension points: what exists in the outline vs later

| Interface                                          | Default implementation (works now)                                                                                                                                                    | Placeholder / later implementation                                                                                                    |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `SessionRegistry` / `SessionController`            | Sessions from `application.yml`, start/stop/reset/set seq nums at runtime                                                                                                             | `DatabaseSessionRegistry` (sessions in PostgreSQL, created from UI)                                                                   |
| `InboundMessageGateway` / `OutboundMessageGateway` | QuickFIX/J adapter                                                                                                                                                                    | (engine swap possible later)                                                                                                          |
| `MessageJournal`                                   | `LoggingMessageJournal` (writes to fix-messages log)                                                                                                                                  | `ChronicleMessageJournal` + async PostgreSQL writer                                                                                   |
| `OrderRepository`                                  | `InMemoryOrderRepository`                                                                                                                                                             | `PostgresOrderRepository`                                                                                                             |
| `UserResolver`                                     | `NoUserResolver` (everything UNASSIGNED)                                                                                                                                              | `TagAliasUserResolver` (configured tags + alias table)                                                                                |
| `FixLevelValidator`                                | `QuickFixDictionaryValidator`                                                                                                                                                         | per-counterparty / Orchestra dictionaries                                                                                             |
| `OrderCorrelator`                                  | `ClOrdIdOrderCorrelator` (11 / 41 / 37 maps)                                                                                                                                          | n/a (core)                                                                                                                            |
| `OrderStateGuard`                                  | `DefaultOrderStateGuard` (unknown 41, terminal state, duplicate ClOrdID)                                                                                                              | per-session policy switches                                                                                                           |
| `BusinessValidator`                                | `BasicBusinessValidator` (qty > 0, price > 0 for limit)                                                                                                                               | `RuleEngineBusinessValidator` (configurable rule sets)                                                                                |
| `TestCaseExecutor`                                 | `NoOpTestCaseExecutor`                                                                                                                                                                | `UatTestCaseExecutor`                                                                                                                 |
| `ActionModeResolver`                               | `ConfigActionModeResolver` (per action from `application.yml`)                                                                                                                        | `ProfileActionModeResolver` (broker profile, per asset class, from DB)                                                                |
| `AutoActionHandler`                                | `DefaultAutoActionHandler` (ack immediately, then full fill at order price)                                                                                                           | auto partial fills, delays, simulator settings                                                                                        |
| `ManualActionHandler`                              | `QueueingManualActionHandler` **placeholder**: logs "awaiting trader action", stores the pending action; UI commands not wired yet                                                    | full manual flow with UI commands                                                                                                     |
| `OrderStateMachine`                                | `TableDrivenOrderStateMachine` (FIX OrdStatus transitions)                                                                                                                            | n/a (core)                                                                                                                            |
| `ExecutionReportBuilder`                           | `DefaultExecutionReportBuilder` (standard tags per FIX version, no templates)                                                                                                         | `TemplateExecutionReportBuilder` (templates + expressions)                                                                            |
| `ExpressionEvaluator`                              | **placeholder** interface only                                                                                                                                                        | compiled expression language (`$unique`, `$now`, …)                                                                                   |
| `OrderEventPublisher`                              | `LoggingOrderEventPublisher`                                                                                                                                                          | `WebSocketOrderEventPublisher` (to BFF)                                                                                               |
| `MetricsRecorder`                                  | `MicrometerMetricsRecorder` (Prometheus endpoint from day 1)                                                                                                                          | more metrics per layer                                                                                                                |
| `AuditRecorder`                                    | `LoggingAuditRecorder` (audit log file)                                                                                                                                               | `PostgresAuditRecorder`                                                                                                               |
| `JobScheduler` + `ScheduledJob`                    | `SpringJobScheduler` (Spring TaskScheduler, cron + time zone from `application.yml`, jobs can be enabled/disabled/triggered manually at runtime)                                      | `DatabaseJobScheduler` (schedules per session/profile in DB, edited in UI); ShedLock when running more than one instance              |
| `ScheduledJob` implementations                     | **placeholders, disabled by default**: `DoneForDayJob` (send DFD for open DAY orders), `ExpireOrdersJob` (expire GTD orders past ExpireDate/ExpireTime and DAY orders at session end) | `SessionScheduleJob` (start/stop sessions on their schedule), `RetentionCleanupJob` (drop data older than 1 year), end-of-day reports |
| `OrderEntryService` (buy side)                     | **placeholder**: accepts a new-order command and logs it                                                                                                                              | Order entry from UI: single orders (D), multileg (AB), cancel (F), replace (G / AC)                                                   |
| `OutboundOrderBuilder` (buy side)                  | **placeholder**                                                                                                                                                                       | Per FIX version builder, later templates for outbound orders                                                                          |
| `ExecutionReportProcessor` (buy side)              | **placeholder**: logs inbound ERs on BUY_SIDE sessions                                                                                                                                | Applies fills / cancels / rejects / busts to our outbound orders, ExecID dedup, CumQty checks                                         |
| `AllocationService` (buy side)                     | **placeholder**                                                                                                                                                                       | Allocations: 35=J out, 35=P / 35=AS in, allocation blotter                                                                            |
| `ReferenceDataProvider`                            | `NoReferenceData` (everything unknown / allowed)                                                                                                                                      | instruments, accounts, limits from DB + CSV import                                                                                    |

Scheduled jobs never change order state themselves: a job submits a command (e.g. "done for day: session X") into the engine's ring buffer, so it goes through the same single-writer path, ActionModeResolver (AUTO sends, MANUAL queues for a trader), state machine, ER builder, journal and audit as a trader click. The actor is recorded as `SYSTEM:<job-name>`.

```yaml
sofix:
  jobs:
    done-for-day:
      { enabled: false, cron: "0 0 16 * * MON-FRI", zone: America/New_York }
    expire-orders: { enabled: false, cron: "0 */1 * * * *", zone: UTC }
```

Domain model in the outline: `Order`, `OrderChain`, `OrderState`, `ExecutionReport`, `ActionType` (ACK, REJECT, FILL, PARTIAL_FILL, CANCEL, REPLACE, DONE_FOR_DAY, EXPIRE), `ActionMode` (AUTO, MANUAL, AUTO_REJECT), `ValidationResult`, `ResolvedUser`, `SessionEnvironment` (UAT, PROD), the exception hierarchy.

## 4. Outline acceptance test

The outline is "done" when, with only default implementations:

1. The app starts, logs the active implementation of every extension point, and exposes `/actuator/health` and `/actuator/prometheus`.
2. A test FIX client (QuickFIX/J initiator in a test) sends a NewOrderSingle → receives an Ack ER (39=0) → receives a Fill ER (39=2, CumQty = OrderQty, LeavesQty = 0).
3. A cancel for an unknown ClOrdID gets an OrderCancelReject (CxlRejReason=1).
4. Switching `sofix.action-mode.fill: MANUAL` makes the order stop after the Ack, and the log shows "awaiting trader action" from the manual placeholder.
5. `./mvnw verify` is green (formatting, Checkstyle, ArchUnit, tests).

## 5. Layers after the outline (one at a time)

| Layer | Fills in                                                                                                                                                     |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1     | Runtime session management (sessions in DB, create/start/stop/reset from API)                                                                                |
| 2     | Persistence: journal + PostgreSQL for orders, messages, audit                                                                                                |
| 3     | REST API + WebSocket event stream for the Node BFF                                                                                                           |
| 4     | Manual mode end to end (trader commands from the UI)                                                                                                         |
| 5     | Configurable business validation rules                                                                                                                       |
| 6     | Execution report templates + expression language                                                                                                             |
| 7     | User resolution by tags + alias table                                                                                                                        |
| 8     | UAT test case execution                                                                                                                                      |
| 9     | Observability stack (Grafana dashboards, Kibana, alerts, traces); basic Prometheus metrics are already in the outline                                        |
| 10    | Buy side: order entry from UI (D, AB, F, G), inbound ER processing, allocations (J, P, AS)                                                                   |
| 11    | More asset classes, FIX versions, Orchestra                                                                                                                  |
| 12+   | Business services from section 2c, in the order the business needs them (likely positions, risk limits + kill switch, reports, P&L, drop copy, trade export) |

Order of layers can change; each layer replaces default implementations without touching the rest.
