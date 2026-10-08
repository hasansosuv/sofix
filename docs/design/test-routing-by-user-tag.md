# Routing inbound FIX messages to a user's test cases, draft 2026-10-08

Requirement (Ahmed, 2026-10-08): several users are logged in at the same time. Each inbound message on a session must be attributed to one user, and that user's test cases are evaluated against it. The user is identified by a configurable tag (116 OnBehalfOfSubID, 57 TargetSubID, or others), and each user can have several aliases (e.g. `aayush.kumar@sofix.com` = `aayush` = `akumar`).

---

## 0. Where test execution fits (Ahmed, 2026-10-08)

Test cases are one feature of a bigger OEMS. Every session has three independent settings:

| Setting            | Values                                                                              | Meaning                                                                                                                                                                                        |
| ------------------ | ----------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Environment**    | `UAT` / `PROD`                                                                      | Set when the session is created.                                                                                                                                                               |
| **Handling mode**  | manual / auto, per action (broker profile, execution-report-templates.md section 8) | How orders are acked, filled, cancelled… Independent of testing.                                                                                                                               |
| **Run test cases** | on / off, **UAT sessions only**                                                     | When on, inbound messages are attributed to a user (sections 2-4) and that user's test cases are fetched and evaluated, while the order is still handled in the session's manual or auto mode. |

- PROD sessions never run test cases; the toggle is not shown and the API refuses it.
- Turning test execution on or off is a runtime change (no restart), audited like other session changes.
- With the toggle off, a UAT session behaves exactly like a PROD session (orders handled, stored, shown on blotters), just with no test evaluation.

## 1. The two flows (corrected by Ahmed, 2026-10-08)

| #   | Flow                                                                                                                                                       | How the user is known                                                                                                                                                                                                                                                                                                              |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A   | **Round trip from our UI**: sofix-ui → BFF → sofix-oems sends an order on session A → external party modifies it → sends it back on session B → sofix-oems | We set tag 116 = the logged-in user's email on the way out (from the BFF's verified identity, not editable in the UI). When it comes back, the configured tags are read. Because the external party may change or drop that tag, we also keep a **correlation fallback**: the ClOrdID (or other id) we sent is mapped to the user. |
| B   | **Order originates outside** (an external application or the external party sends the order and later cancels/replaces)                                    | Configured tags, e.g. 116=ahasan → alias → ahmed.hasan@sofix.com. Later messages in the same order chain inherit the user from the order (section 3).                                                                                                                                                                              |

## 2. Configuration per session: the user resolution rule

Each inbound session has an ordered list of where to look:

```yaml
session: CLIENT_B_IN
userResolution:
  sources: # first non-empty match wins
    - { tag: 116, location: HEADER } # OnBehalfOfSubID
    - { tag: 57, location: HEADER } # TargetSubID
    - { tag: 50, location: HEADER } # SenderSubID
    - { tag: 1, location: BODY } # Account (example)
    # later: Parties group, e.g. 448 where 452 = 11 (Order Origination Trader)
  matchMode: CASE_INSENSITIVE_TRIMMED
  onNoMatch: UNASSIGNED # UNASSIGNED | SESSION_DEFAULT_USER | REJECT
  sessionDefaultUser: null
```

- Any tag can be configured, in the header or the body.
- **UI**: the session settings screen has a "User identification" section with **Primary tag**, **Alternative 1**, **Alternative 2**, … (add / remove / reorder), each with tag number and header/body.
- **onNoMatch (Ahmed, 2026-10-08)**:
  - **Auto mode**: the order is rejected by the application with an ExecutionReport 150=8 / 39=8 and 58 = "User details missing" (text configurable in the Reject template). For a cancel/replace that cannot be matched to a known order, the normal unknown-order rule applies (OrderCancelReject 9).
  - **Manual mode** (later): the order waits in an "Unattributed" queue; a trader rejects it and types the reason in tag 58.
  - The message is still stored and visible to admins.

## 3. Resolution order for one inbound message

1. **Order chain**: if the message belongs to an order chain we already know (tag 41 / 37 / 11 matches an existing order, or it is the return leg of an order we sent in flow 1), use that order's user. This makes cancels, replaces and returning round-trip messages stable even if the external party changed tag 116.
2. **Configured tags**, in the session's order: read the value, normalise it (trim, lower-case), look it up in the alias table.
3. **onNoMatch** policy.

The message, the order and every test result store the resolved `user_id` **and how it was resolved** (e.g. `tag 116 = "ahasan" → alias → ahmed.hasan@sofix.com`, or `order chain`), shown in the message detail so a wrong attribution is easy to debug.

## 4. Alias table

Users live in the `ui` database, but the alias lookup runs inside the engine on every inbound message, so the alias table lives in the **`oems` database** (owned by sofix-oems), keyed by the stable user id. It is managed from the UI (user profile screen and admin screen) through the BFF → engine API.

```
user_identity_alias
  alias_id        PK
  user_id         stable user id (from the ui database / SSO)
  alias_value     stored normalised (trimmed, lower-case), e.g. 'aayush', 'akumar'
  scope_session   NULL = all sessions, or one session id (same alias can mean different users on different sessions)
  created_by, created_at
  UNIQUE (scope_session, alias_value)
```

- The user's email is always an implicit alias; extra aliases are added by the user or an admin.
- **One alias → exactly one user** within a scope; the unique constraint and a check on save prevent two users claiming `akumar`.
- The engine keeps the whole table in memory (a hash map from alias to user id), updated by snapshot swap when an alias changes. Lookup is a map hit with no allocation.

## 5. Picking the test cases for that user (still to be discussed with Ahmed)

Resolving the user tells us _whose_ test cases to use. It does not yet say _which_ of that user's test cases a message belongs to. Recommended model:

- The user **starts a test run** in the UI: picks one test case or suite (their own, or a public one), optionally restricted to a session. That run becomes **active** for that user.
- An inbound message resolved to user X is evaluated against **X's active run(s)**: the test engine matches it to the next expected step (message type, expected tags/values, expected state).
- Several users can have active runs at the same time on the same session; attribution by tag keeps them apart.
- If X has no active run, the message is processed and stored normally (and shown in X's message history), but no test is evaluated.
- **Tests only run for a logged-in user (Ahmed, 2026-10-08)**: if X is not logged in, no test cases are executed, so someone mistakenly sending orders with X's tag 116 does not run or pollute X's tests. The order itself is still processed by the broker profile and stored, attributed to X.
- "Logged in" is known by the engine from the BFF: the BFF reports login, logout and session expiry (and periodically refreshes presence); the engine keeps an in-memory set of present users.

Live progress goes to the user's browser over the WebSocket; results are stored per run with the FIX messages of each step, owned by that user (private by default, publishable, per components-and-data-ownership.md).

## 6. Outbound side

- Flow 1: when sofix-oems sends an order for user X, it sets the identity tag (116 by default, configurable per outbound session) to X's email or chosen alias, and records ClOrdID → user X for the correlation fallback.
- Replies to an external party: standard FIX routing convention echoes OnBehalfOfCompID/SubID (115/116) back as DeliverToCompID/SubID (128/129). This is handled by the execution report templates (an echo rule), not hard-coded.

## 7. Notes

- Identity tags are supplied by the counterparty, so they decide **which test results a message belongs to**, not who is allowed to see data. Visibility is still enforced by owner/visibility on the stored results.
- Metrics: messages attributed per user, unattributed messages count, alias conflicts.

## 8. What each user sees (Ahmed, 2026-10-08)

**Blotter**

- Orders attributed to a user appear on that user's blotter **whether they came from the UI or from an external application** (the user may send orders from their own external app).
- Visibility by role (roles and permissions live in the `ui` database, managed in the UI):

| Permission         | Typical role    | Sees on the blotter                                    |
| ------------------ | --------------- | ------------------------------------------------------ |
| `orders.view.own`  | Normal user     | Only their own orders                                  |
| `orders.view.team` | Team lead       | Own + their group's orders                             |
| `orders.view.all`  | Admin / manager | All orders on all sessions, plus unattributed messages |

- Queries: sofix-oems filters by the user id, groups and permissions in the BFF's token. Live events: each event carries the owning user id (and group); the BFF only forwards it to browsers allowed to see it.

**Test results panel**

- Shows only results of test runs that ran for that user (their runs, against their own test cases or public ones they ran). Other users' results are not shown, unless they are published, or the viewer has an admin/manager permission (`tests.view.all`).
