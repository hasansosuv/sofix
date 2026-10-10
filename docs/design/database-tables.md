# Database tables (broker side, v1), draft 2026-10-10

Question (Roma, 2026-10-10): what tables will we have in the database?

One PostgreSQL server, two databases, each owned by one service (components-and-data-ownership.md):
* **`ui`**, owned by the Node.js BFF: people, permissions, screen layouts.
* **`oems`**, owned by sofix-oems: clients, sessions, configuration, orders, messages, certification.

Reflects today's decisions: one application owner, all users belong to the owner, companies are clients (application-scope-and-tenancy.md); order lifecycle and persistence by TIF (order-lifecycle-and-persistence.md); parent / child orders (order-hierarchy.md). Every `oems` table also has a `tenant_id` column with one fixed value on the broker desk, so the buy-side SaaS deployment can reuse the same schema later (application-scope-and-tenancy.md section 7). Common audit columns on every table: `created_at`, `created_by`, `updated_at`, `updated_by`.

---

## A. `ui` database (Node.js BFF)

| # | Table | What it holds |
|---|---|---|
| 1 | `app_user` | Our users: id, login (email), display name, status (ACTIVE / LOCKED / DISABLED), last login |
| 2 | `user_credential` | Password hash and MFA secret, or the SSO subject id when an identity provider is used |
| 3 | `user_login_session` | Active logins and refresh tokens, for logout and forced sign-out |
| 4 | `team` | Teams / groups (desk, sales team) |
| 5 | `team_member` | User ↔ team, with team-lead flag |
| 6 | `role` | Named roles (Trader, Sales trader, Manager, Ops, Tester, Admin) |
| 7 | `permission` | Catalogue of permissions (orders.view.own, orders.view.clients, orders.act.all, sessions.manage, …) |
| 8 | `role_permission` | Which permissions a role has |
| 9 | `user_role` | Which roles a user has |
| 10 | `user_visibility_scope` | Extra scopes an admin assigns: "this manager sees users A1, A2, A3" or "team X" |
| 11 | `workspace_layout` | Saved panel layouts and workspaces per user (and shared ones) |
| 12 | `user_preference` | Theme, time zone, blotter columns, child-order display, default filters |
| 13 | `saved_filter` | Named blotter filters |
| 14 | `ui_audit_log` | Logins, failed logins, permission and role changes |

## B. `oems` database (sofix-oems)

### B1. Clients (companies)

| # | Table | What it holds |
|---|---|---|
| 1 | `client_company` | Profile: legal name, short code, type, status, country, time zone, addresses, LEI / BIC |
| 2 | `client_contact` | Trading desk, FIX support, ops, compliance contacts |
| 3 | `client_hub_identity` | Client's identifier per hub (NYFIX 115 = VANG, Autex 115 = BLK) |
| 4 | `client_account` | Accounts and sub-accounts (tag 1), allocation accounts |
| 5 | `client_limit` | Per-client / per-account limits (order size, daily value, credit) |
| 6 | `client_coverage` | Which of our users / teams cover which client (order visibility, PROD attribution) |
| 7 | `client_trading_setup` | Broker profile assigned to the client, allowed asset classes and order types |

### B2. Users as the engine sees them

| # | Table | What it holds |
|---|---|---|
| 8 | `user_identity_alias` | Values in 116 / 57 / 129 that map to one of our users (routing-inbound-order-to-user.md) |

(User names, roles and teams stay in `ui`; the engine only gets the user id and permissions in the BFF token.)

### B3. FIX sessions

| # | Table | What it holds |
|---|---|---|
| 9 | `hub` | Networks: NYFIX, Autex, … |
| 10 | `fix_session` | FIX settings: CompIDs, version, acceptor / initiator, host / port, heartbeat, schedule, environment UAT / PROD, type DEDICATED / HUB, client (dedicated) or hub |
| 11 | `session_business_config` | Versioned business settings: role, profile, allowed messages, asset classes, handling mode, user tags, run tests (UAT), end-of-day time |
| 12 | `session_event` | Audit of session actions: created, started, stopped, logon, logout, sequence reset, who did it |
| 13 | `qfj_sessions`, `qfj_messages` | QuickFIX/J's own store: sequence numbers and sent messages for resends (table names fixed by QuickFIX/J) |

### B4. Configuration (versioned, auditable)

| # | Table | What it holds |
|---|---|---|
| 14 | `broker_profile` | Bundle: rule set + template set + automation policy |
| 15 | `validation_rule_set`, `validation_rule` | Business validation rules (order-validation-rules.md) |
| 16 | `message_template_set`, `message_template`, `message_template_tag` | ER templates per asset class and ER type, tag classes and expressions (execution-report-templates.md) |
| 17 | `automation_policy`, `automation_policy_action` | Manual / auto per action, session overrides |
| 17b | `user_action_mode`, `action_mode_lock` | Each user's manual / auto setting per action (optionally per session or client), and admin locks users cannot override |
| 18 | `message_key_config` | Id and reference tags per message type, per session override |
| 19 | `config_change` | Every config change: before / after, who, when, approval (four-eyes on PROD) |

### B5. Reference data

| # | Table | What it holds |
|---|---|---|
| 20 | `instrument` | Symbol, asset class, exchange (MIC), currency, lot size, tick size, option / future details |
| 21 | `instrument_identifier` | ISIN, CUSIP, SEDOL, RIC, Bloomberg per instrument (symbology) |
| 22 | `instrument_leg` | Legs of multi-leg instruments (spreads, buy-write) |
| 23 | `reference_price` | Previous close / reference price per instrument and day |
| 24 | `trading_calendar`, `holiday` | Trading days and holidays per market |

### B6. Orders and messages (the core)

| # | Table | What it holds |
|---|---|---|
| 25 | `orders` | One row per order: ids (OrderID 37, current ClOrdID 11), client, user, session, kind CLIENT / MANUAL / STREET, parent / root order, symbol, side, qty, price, TIF, expire date, OrdStatus, CumQty, AvgPx, LeavesQty, live flag |
| 26 | `order_version` | One row per accepted request (D, each accepted G) with its ClOrdID, 41 and fields |
| 27 | `order_leg` | Legs of a multi-leg order |
| 28 | `order_event` | Every change to an order with actor (CLIENT = client FIX message, TRADER = user action in the UI, AUTO = automatic action per policy, BROKER = ExecutionReport / cancel reject from the next broker on a street child, SYSTEM = scheduled job / recovery), event type, state after, reason, user id, link to the FIX message; drives the lifecycle view. Messages that change nothing (heartbeats, duplicate resends) create no event |
| 29 | `execution` | Every fill, bust and correction: 17 ExecID, 19 ExecRefID, LastQty, LastPx, LastMkt |
| 30 | `pending_action` | Orders waiting for a trader (manual ack, fill, cancel accept) |
| 31 | `fix_message` | Every FIX message in and out: raw text + key columns (session, client, direction IN / OUT, side CLIENT / STREET, MsgType, seq num, 11, 41, 37, 17, 19) + order link (order_id and root_order_id); client-side and street-side messages share this one table (Roma, 2026-10-10); partitioned by day, 1-year retention from order close |
| 32 | `unmatched_message` | Messages we could not link (unknown client on a hub, unknown 41) for ops review |

### B7. Certification (UAT)

| # | Table | What it holds |
|---|---|---|
| 33 | `test_case`, `test_case_step` | Test cases owned by a user, with visibility (private / team / public) |
| 34 | `test_suite`, `test_suite_case` | Groups of test cases |
| 35 | `test_run`, `test_step_result` | Runs and per-step results, linked to the FIX messages |
| 36 | `atdl_spec` | Algo (ATDL) files and their parsed form |
| 37 | `order_preset` | Saved order tickets / presets |

### B8. Platform

| # | Table | What it holds |
|---|---|---|
| 38 | `journal_checkpoint` | Last journal entry written to the database; used on restart to replay only the rest (crash recovery) |
| 39 | `engine_event_log` | Numbered events sent to the BFF, so it can resume after a reconnect |
| 40 | `scheduled_job_run` | Runs of DFD, expiry, GTC carry-over, retention jobs and their results |
| 41 | `alert` | Alerts raised (session down, unmatched message, limit breach) and who acknowledged them |
| 42 | `id_sequence` | Counters for OrderID / ExecID generation that must survive restarts |

### Later (placeholders now, tables when the layer is built)

`position`, `commission_schedule`, `drop_copy_target`, `trade_report_export`, `regulatory_report`, and on the buy side `broker_connection`, `allocation`, `allocation_detail`.

---

## C. Notes

* **Big tables**: `fix_message`, `execution`, `order_event` are partitioned by day so retention just drops old partitions; `orders` keeps a `live` index for fast restart loading.
* **Migrations**: `oems` with Flyway (in the engine repo), `ui` with the Node migration tool; neither service ever touches the other's database.
* **Secrets**: no FIX passwords in `fix_session`, only a reference to the secrets store; 554 / 925 are masked in `fix_message`.
