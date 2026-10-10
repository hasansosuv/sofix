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
| Handling mode | Manual / auto per action (ack, reject, fill, cancel, replace, DFD, expire), kill switch to full manual | ✓ | (later: auto-cancel on disconnect etc.) |
| Validation | Rule set (Retail / Institutional / Simulator / custom) | ✓ | pre-trade rule set |
| **Testing** | Run test cases on/off (**UAT only**; hidden and refused on PROD) | ✓ | ✓ |
| User identification | Primary tag + Alternative 1, 2… (header/body), behaviour on no match | inbound | outbound identity tag (116) |
| Other | Throttle (max msgs/sec), drop copy target session, symbology mapping, trading calendar, ClOrdID format (buy side), ATDL files (buy side) | ✓ | ✓ |

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
