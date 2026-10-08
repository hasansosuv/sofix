# Components, communication and data ownership, draft 2026-10-08

Context (Ahmed, 2026-10-08): the system is

1. **UI**: Angular application + its **Node.js backend** (BFF)
2. **sofix-oems**: Spring Boot service running the FIX engine (QuickFIX/J) and talking to external FIX counterparties

Data mentioned: users, roles, permissions, groups, layouts (UI side); sessions, certification test cases, ATDL files, test results, orders, messages (engine side). Certification items must belong to the user who created them, and can also be published for all users.

---

## 1. Who talks to whom

```
 Browser (Angular)
   │  HTTPS REST  (login, commands, queries)
   │  WebSocket   (live orders, session status, test progress, metrics)
   ▼
 Node.js backend (BFF)  ──────────►  PostgreSQL: database "ui"
   │  authenticates users, checks roles/permissions,
   │  stores layouts, fans events out to browsers
   │
   │  HTTPS REST (commands + queries, OpenAPI contract)
   │  WebSocket   (one event stream from engine → BFF)
   │  every call carries a signed service token + the user's id, groups, roles
   ▼
 sofix-oems (Spring Boot + QuickFIX/J) ──►  PostgreSQL: database "oems"
   │
   │  FIX over TCP (acceptor and/or initiator per session)
   ▼
 External FIX clients / brokers / venues
```

Rules:

- **The browser never talks to sofix-oems directly.** Only the Node backend does. sofix-oems is not exposed outside the internal network.
- **Each service owns its own database** and is the only one that reads or writes it. If the BFF needs engine data, it asks sofix-oems through its API, never by querying the `oems` database.
- **Commands** (start session, ack order, run test case, upload ATDL) go Browser → BFF (REST) → sofix-oems (REST). Every command has a `commandId` for safe retries.
- **Events** (order updated, session logged on, test step passed, metrics tick) go sofix-oems → BFF over one WebSocket stream, then BFF → each browser that is allowed to see them. Each event has a sequence number; after a reconnect the BFF resumes from the last number it saw.
- BFF ↔ engine: earlier draft proposed gRPC. With a Node.js BFF, plain REST (OpenAPI, with a generated TypeScript client) plus a WebSocket event stream is simpler and enough for UI traffic. gRPC remains an option if needed later.

## 2. One database or two?

**Recommendation: one PostgreSQL server, two separate databases (`ui` and `oems`), each with its own login and owned by one service.**

| Option                                                           | Verdict                                                                                                                                                                                                                 |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| One database, shared tables, both services read/write everything | No. Both services become coupled to each other's tables; a UI migration can break the engine; the engine's hot path would share locks/load with UI queries; no clear security boundary.                                 |
| **One server, two databases (or two schemas), one owner each**   | **Yes.** Clean ownership and independent migrations (Flyway for `oems`, the Node migration tool for `ui`), still one server to run, back up and monitor. Can be split onto separate servers later without code changes. |
| Two separate database servers from day one                       | Not needed now. More to operate for no gain at this scale.                                                                                                                                                              |

### What lives where

| `ui` database (owned by Node BFF)     | `oems` database (owned by sofix-oems)                    |
| ------------------------------------- | -------------------------------------------------------- |
| users, credentials / SSO links        | FIX sessions + session audit                             |
| roles, permissions                    | orders, order events, executions                         |
| groups, group membership              | FIX messages (1-year retention)                          |
| layouts, workspaces, user preferences | certification test cases, test suites                    |
| UI audit (logins, permission changes) | test runs and results (per step, with the FIX messages)  |
|                                       | ATDL / algo specs (files + parsed form)                  |
|                                       | ER templates, validation rules, profiles, reference data |

## 3. Tying engine data to users (private / group / public)

The engine does not store user details, only the **user id** (the stable id from the `ui` database or SSO). Every user-owned record in `oems` (test case, test suite, test run, ATDL spec, and optionally session) carries:

| Column                                   | Meaning                                                               |
| ---------------------------------------- | --------------------------------------------------------------------- |
| `owner_user_id`                          | who created it                                                        |
| `visibility`                             | `PRIVATE` (only owner), `GROUP` (owner's group), `PUBLIC` (all users) |
| `group_id`                               | for `GROUP` visibility                                                |
| `created_at`, `updated_at`, `updated_by` | audit                                                                 |

How a request works:

1. The user logs in to the BFF; the BFF knows their id, groups and roles.
2. For each call to sofix-oems, the BFF sends a short-lived signed token containing `userId`, `groupIds`, `roles`.
3. sofix-oems verifies the token and filters every query: `owner_user_id = me OR visibility = PUBLIC OR (visibility = GROUP AND group_id IN my groups)`. Admins see everything.
4. The BFF adds display names (from the `ui` database) before sending results to the browser.

So "my history, my test cases, my algo specs" is the default view; **Publish** switches a record to `PUBLIC` (or `GROUP`), and others can view or **copy** it into their own private space (copy rather than edit, so nobody changes someone else's test case). Who may publish, and who may edit public items, is a permission managed in the `ui` database.

The engine enforces visibility itself (not only the BFF), because it owns the data: a bug in the UI layer can then never leak another user's test results.

## 4. Open points

- Frontend framework: this note says Angular; the earlier VAYU FIX HUB documentation describes React/TypeScript. Which one is this UI?
- Ahmed's message ended with "also the…": the rest of that point is still to come.
- Users and roles: built in the Node BFF as described, or delegated to an identity provider (Keycloak / Azure AD / Okta) with the `ui` database keeping only groups, layouts and preferences. Recommendation: start in the BFF with a clean interface so an identity provider can be plugged in later.
