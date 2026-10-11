# Session configuration: FIX settings vs business settings, draft 2026-10-08

Requirement (Ahmed, 2026-10-08): a session has two kinds of information, FIX connection settings and business-level configuration, shown in separate panels. Business details can be given when the session is created or filled in later.

---

## 1. Two panels, two lifecycles

|  | **FIX Settings** panel | **Business Settings** panel |
| --- | --- | --- |
| What | How we connect and speak FIX | What the session is allowed to do and how orders are handled |
| Who edits | Ops / admin (permission `sessions.fix.edit`) | Ops, desk lead (permission `sessions.business.edit`) |
| When changes apply | Most need a **session restart** (logout/logon); the UI shows "restart required" and offers to do it | **Live**, no reconnect: the engine swaps in the new version atomically; open orders keep the version they started with |
| Versioned + audited | Yes | Yes |

## 2. FIX Settings panel

- **Identity**: session name, BeginString / DefaultApplVerID (FIX version), SenderCompID / SubID / LocationID, TargetCompID / SubID / LocationID
- **Connection**: connection type (ACCEPTOR / INITIATOR); listen port (acceptor) or host + port + reconnect interval + failover hosts (initiator); TLS on/off + certificates
- **Logon**: heartbeat interval, Username (553) / Password (554) (stored as a secret, masked everywhere), ResetSeqNumFlag on logon, reset on logout / disconnect
- **Schedule**: start/end time, days, time zone, or "always on"
- **Protocol**: data dictionary (standard or counterparty-specific / Orchestra), validation switches (out-of-order fields, unknown fields, user-defined fields), timestamp precision, resend behaviour
- **Runtime controls** (buttons, not settings): start, stop, reset sequence numbers, set next sender / target seq num, view message log

## 3. Business Settings panel

Required at creation (they decide which pipeline the session uses): **Role** (SELL_SIDE / BUY_SIDE) and **Environment** (UAT / PROD). Everything else defaults to the **Default profile** and can be filled in later; the session list shows a "default business config" badge until someone does.

| Section | Settings | Sell side | Buy side |
| --- | --- | --- | --- |
| General | Role, environment, description, owning team, enabled | ✓ | ✓ |
| Profile | Broker profile (sell) or buy-side profile; per-session overrides of any part below | ✓ | ✓ |
| **Allowed inbound messages** | Checklist of MsgTypes we accept. Defaults: sell side D, F, G, AB, AC, H, q; buy side 8, 9, j, P, AS. Anything else → BusinessMessageReject (35=j, 380=3 Unsupported Message Type) | ✓ | ✓ |
| Allowed outbound messages | Which messages users may send from the UI (e.g. D and AB but not q) |  | ✓ |
| **Allowed asset classes** | Equity, Future, Option, Multileg, Fixed Income. Order in a disallowed class → ER Rejected (39=8, 58 "Asset class not allowed") | ✓ | ✓ |
| Allowed order types / TIFs | Quick lists (Market, Limit, Stop…; DAY, GTC, IOC…). Detailed checks live in the rule set | ✓ | ✓ |
| **Message templates** | Template set per asset class (grid: message type × asset class, inherited cells marked), single-cell overrides | ERs | D, AB, F, G, AC, J |
| Handling mode | Manual / auto **per incoming message** (D, G, F; default Manual), auto with a lifecycle and fill plan (see below), kill switch to full manual (later) | ✓ | (later: auto-cancel on disconnect etc.) |
| Validation | Rule set (Retail / Institutional / Simulator / custom) | ✓ | pre-trade rule set |
| **Testing** | Run test cases on/off (**UAT only**; hidden and refused on PROD) | ✓ | ✓ |
| User identification | Primary tag + Alternative 1, 2… (header/body), behaviour on no match | inbound | outbound identity tag (116) |
| Other | Throttle (max msgs/sec), drop copy target session, symbology mapping, trading calendar, ClOrdID format (buy side), ATDL files (buy side) | ✓ | ✓ |

**Decided and built (Roma, 2026-10-11): handling per incoming message.**

* The handling mode is set **per incoming application message type**, not per action: today 35=D (NewOrderSingle), 35=G (OrderCancelReplaceRequest) and 35=F (OrderCancelRequest). The list is fixed in code (`ConfigurableMessageType` in sofix-oems); the user adds a message from that list and sets its mode. Session-level messages (Logon, Heartbeat, TestRequest, ResendRequest, SequenceReset, Reject 35=3, Logout) are handled by QuickFIX/J and are never configurable.
* **Default: MANUAL for every message**; a message not listed is MANUAL.
* **AUTO** opens a dialog that defines the lifecycle:

| Message | AUTO lifecycle |
|---|---|
| D | Pending New (39=A, optional) → delay → Ack (39=0) → fills: a trader, or automatic |
| G | Pending Replace (39=E, optional) → delay → Replaced → fills: a trader, or automatic |
| F | Pending Cancel (39=6, optional) → delay → Canceled (no fills) |

* Automatic fills: up to **N % of the quantity** (what is filled counts; after a replace, of the new quantity) in **S steps**, **T ms apart**, at the order's limit price, or a set price for market orders. "Fill completely in 4 steps" = 100 % / 4; "half, then stop" = 50 % / 1, leaving quantity to replace.
* **Identity tag** (default 116) is a business setting too: the tag that carries the user's username on orders we send.
* Stored in the `oems` database (`session_business_config`, `session_message_mode` with the lifecycle as JSON), edited in the **Session Business Configuration** panel, audited in the session audit trail. The engine follows the settings once order handling runs in the OEMS (sofix-oems `docs/how-it-works/session-business-config.md`).
* Later, on the same shape: per-user settings and admin locks (execution-report-templates.md §8b), and more message types.

## 4. Where this sits in the engine

- New domain type `SessionBusinessConfig` (immutable snapshot, versioned) next to `SessionFixConfig`.
- Two new pipeline steps right after FIX-level validation, both reading the snapshot:
  - `AllowedMessageFilter`: rejects message types not in the allowed list
  - `AssetClassFilter`: rejects orders in disallowed asset classes
- Profile, templates, rules, handling mode, testing and user identification are already extension points; they now take their settings from `SessionBusinessConfig` instead of global config.
- In the outline (before the DB layer) both configs come from `application.yml` per session; the Default profile applies when nothing is set.

## 5. UI flow

1. **Create session** wizard: step 1 FIX settings (required), step 2 Role + Environment (required), step 3 business settings (optional: "use Default profile and configure later").
2. Session detail screen: tabs **FIX Settings** | **Business Settings** | **Status & Controls** | **Messages** | **History** (version list of both configs with diff and rollback).
