# Execution Report Templates (broker side), draft 2026-10-04

Requirement (Ahmed, 2026-10-08);: the ExecutionReports (and cancel rejects) the broker sends must be configurable. For each kind of report we define which tags are sent and where each value comes from. Some tags are calculated internally from the order state and can never be changed by a user; some are entered by the trader in the UI (e.g. tag 30 LastMkt on a manual fill); some are fixed values or small functions in the template (like `$unique` for generating a unique id). Which reports are sent at all must also be configurable.

---

## 1. Report types (one template each)

| Report type                    | Message | ExecType (150) / OrdStatus (39) | Can be switched off?                                |
| ------------------------------ | ------- | ------------------------------- | --------------------------------------------------- |
| Pending New                    | 8       | A / A                           | Yes (optional, sent automatically on receipt if on) |
| Ack (New)                      | 8       | 0 / 0                           | No                                                  |
| Reject                         | 8       | 8 / 8                           | No                                                  |
| Partial Fill                   | 8       | F (4.2: 1) / 1                  | No                                                  |
| Fill                           | 8       | F (4.2: 2) / 2                  | No                                                  |
| Done For Day                   | 8       | 3 / 3                           | No (only sent when the trader chooses it)           |
| Pending Cancel                 | 8       | 6 / 6                           | Yes                                                 |
| Canceled                       | 8       | 4 / 4                           | No                                                  |
| Pending Replace                | 8       | E / E                           | Yes                                                 |
| Replaced                       | 8       | 5 / current                     | No                                                  |
| Cancel Reject / Replace Reject | 9       | n/a                             | No                                                  |
| Restated                       | 8       | D / current                     | No                                                  |
| Expired                        | 8       | C / C                           | No                                                  |
| Trade Cancel / Trade Correct   | 8       | H / G                           | No                                                  |

"Switched off" applies only to reports FIX treats as optional. The template editor refuses to disable a mandatory one (e.g. a Canceled after an accepted cancel request), so a configuration can never produce an invalid FIX conversation.

Workflow options in the same config (per template profile): auto-send Pending New on receipt, auto-send Pending Cancel / Pending Replace on request, allow "Ack + Fill" in one action, auto-ack on/off.

## 2. Four kinds of tags

| Kind                | Who sets the value                                         | User can change?                                 | Examples                                                                                                                                                                              |
| ------------------- | ---------------------------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Engine (locked)** | Calculated from the order state by the engine              | Never: not in templates, not in the UI           | 11 ClOrdID, 41 OrigClOrdID, 37 OrderID, 17 ExecID, 150 ExecType, 39 OrdStatus, 14 CumQty, 151 LeavesQty, 6 AvgPx, 20 ExecTransType (4.2), header tags 8/9/34/49/56/52/10 (QuickFIX/J) |
| **Echoed (locked)** | Copied from the current version of the order               | Never                                            | 55 Symbol, 54 Side, 38 OrderQty, 40 OrdType, 44 Price, 59 TimeInForce, 1 Account, plus any other inbound tag the template chooses to echo                                             |
| **Trader input**    | Typed by the trader in the action dialog (Fill, Reject, …) | Yes, within the template's rules                 | 32 LastQty, 31 LastPx, 30 LastMkt, 29 LastCapacity, 58 Text, 103 OrdRejReason, 851 LastLiquidityInd                                                                                   |
| **Template value**  | Fixed value or expression in the template                  | Yes, by whoever edits templates (ops/admin role) | 30 LastMkt default `XNYS`, 382 NoContraBrokers, custom tags (e.g. 5000+), 60 TransactTime = `$now`                                                                                    |

Trader input still goes through engine checks: LastQty must be > 0 and ≤ LeavesQty, LastPx > 0 and within the price collar, and the engine then recalculates CumQty / LeavesQty / AvgPx itself.

**Precedence for one tag:** engine/echoed (locked) > trader input > template value > profile default > not sent.

## 3. Template field definition

Each field in a template has:

- `tag` (validated against the session's FIX dictionary)
- `source`: `CONSTANT` | `EXPRESSION` | `TRADER_INPUT` | `ECHO`
- `value`: the constant or the expression (for CONSTANT/EXPRESSION), or the default (for TRADER_INPUT)
- For TRADER_INPUT: `label`, `required`, allowed values (enum list) or pattern, `remember last value` option. The UI builds the action dialog from these fields, so adding tag 30 to the Fill template automatically adds a LastMkt field to the Fill dialog.
- `condition` (optional): only send the tag when the condition is true (e.g. only for options, only for FIX 4.4+)

Example (Fill):

```yaml
template: Fill
profile: default-equities-4.4
fields:
  - {
      tag: 30,
      source: TRADER_INPUT,
      label: "Last market",
      required: true,
      allowed: [XNYS, XNAS, ARCX, BATS],
      default: XNYS,
    }
  - {
      tag: 29,
      source: TRADER_INPUT,
      label: "Capacity",
      allowed: ["1", "2", "3", "4"],
      default: "1",
    }
  - { tag: 60, source: EXPRESSION, value: "$now" }
  - { tag: 75, source: EXPRESSION, value: "$tradeDate" }
  - { tag: 5001, source: EXPRESSION, value: "$unique(10)" }
  - { tag: 1, source: ECHO }
  - { tag: 58, source: TRADER_INPUT, label: "Text", required: false }
```

## 4. Expression functions

A small, purpose-built expression language (not SpEL, not JavaScript): safe (cannot call arbitrary code) and compiled once when a template is activated, so sending a report does no parsing and stays allocation-free.

| Function                                                | Result                                                                  |
| ------------------------------------------------------- | ----------------------------------------------------------------------- |
| `$unique` / `$unique(n)`                                | Unique id (optionally n characters), unique per session per day         |
| `$seq(name)`                                            | Next value of a named counter (e.g. per-session trade number)           |
| `$now`                                                  | Current UTC timestamp (FIX format, session's precision)                 |
| `$tradeDate`                                            | Current trade date (YYYYMMDD, per session calendar)                     |
| `$order.tag(n)`                                         | Value of tag n from the original inbound order                          |
| `$order.<field>`                                        | Order fields: clOrdId, orderId, symbol, side, orderQty, price, account… |
| `$input.<name>`                                         | A trader-input value (to reuse it in another tag)                       |
| `$session.<field>`                                      | senderCompId, targetCompId, …                                           |
| `$default(a, b)`                                        | a if present, otherwise b                                               |
| `$concat(a, b, …)`, `$upper(a)`, `$substr(a, from, to)` | String helpers                                                          |

The exact syntax should match what is already used for `$unique` in the local FIX OEMS code, so there is one expression style everywhere.

## 5. Storage, versioning, inheritance

- Templates are stored in PostgreSQL as versioned config (same rules as all config: who/when/why, rollback, activated as an atomic in-memory snapshot).
- **Template profiles**: a profile (e.g. `default-equities-4.4`, `options-4.4`, `client-X`) contains one template per report type. Sessions point to a profile; a session can override individual templates. Built-in defaults per FIX version are shipped so a new session works immediately.
- Each sent ExecutionReport stores the template version used, for audit and debugging.

## 6. Validation when saving a template

- Every tag exists in the session's dictionary for its FIX version.
- No locked tag (engine or echoed) is defined or overridden.
- All tags FIX requires for that report type are covered (by engine, echo or template).
- Expressions parse and reference only known functions and fields.
- Mandatory report types are not disabled.
- **Preview**: the editor shows the exact FIX message the template would produce for a sample order, before it is activated.

## 7. UI

- **Template editor** (admin/ops role): profiles, report types, field list, enable/disable optional reports, preview, version history.
- **Trader action dialogs** (Fill, Partial Fill, Reject, …) are generated from the template's TRADER_INPUT fields, with defaults pre-filled; locked values (CumQty, LeavesQty, AvgPx after the fill) are shown read-only as a preview.

---

## 8. Automation policy: manual vs auto per action (Ahmed, 2026-10-04)

The broker has a manual mode and an auto mode, and the choice is made **per action**, not all-or-nothing. Every trader action can be set to MANUAL (waits for a trader in the UI), AUTO (the engine does it), or for some actions AUTO_REJECT.

| Trigger                              | Action         | Options                                                | Auto parameters                                                                                                                                          |
| ------------------------------------ | -------------- | ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| New order received (valid)           | Ack            | MANUAL / AUTO                                          | Delay (ms)                                                                                                                                               |
| New order failed business validation | Reject         | AUTO (default) / MANUAL (trader reviews before reject) | Reject reason from the failed rule                                                                                                                       |
| Order acked                          | Fill           | MANUAL / AUTO_FULL / AUTO_PARTIAL                      | Price source (order limit price / fixed price / later market data), number of partial fills, interval between fills, LastMkt etc. from template defaults |
| Cancel request received              | Accept cancel  | MANUAL / AUTO / AUTO_REJECT                            | Delay; reject reason                                                                                                                                     |
| Replace request received             | Accept replace | MANUAL / AUTO / AUTO_REJECT                            | Delay; reject reason                                                                                                                                     |
| End of trading day                   | Done For Day   | MANUAL / AUTO at session end time                      | Time                                                                                                                                                     |
| DAY order past session end           | Expire         | MANUAL / AUTO                                          | Time                                                                                                                                                     |
| Pending manual action too long       | Escalate       | OFF / ALERT / AUTO_REJECT after N seconds              | Timeout                                                                                                                                                  |

Examples of combinations this supports:

- Manual ack, manual fill (full care desk).
- Auto ack, manual fill (trader only works fills).
- Auto ack + auto fill + auto cancel (simulator / UAT counterparty).
- Manual ack but auto-accept cancels.

Rules:

- **Scope**: the policy lives in the same profile as the templates (sessions point to a profile, can override single actions). Optional later: conditions per rule (e.g. auto-ack only below a quantity or for certain accounts).
- **Same path as a trader**: an automated action goes through exactly the same engine path as a click (state checks, templates, validation, journal, audit). The only difference is the actor, recorded as `AUTO:<rule-id>` instead of a user name.
- **Runtime switch**: an ops user can flip a session (or all sessions) to full manual instantly from the UI, a kill switch for automation, without restart. The change is audited.
- **Visible**: the blotter shows which actions on an order were automatic, and the metrics show auto vs manual counts.

---

## 9. Templates per asset class (Ahmed, 2026-10-04)

Templates are chosen by **profile + asset class + report type**. A profile contains template sets for each asset class it supports, e.g. Equity Fill, Future Fill, Option Fill, Multileg Fill, Fixed Income Fill, each with its own tags (an option Fill can carry 77 PositionEffect, 201 PutOrCall, 202 StrikePrice, 541 MaturityDate; a future Fill 200 MaturityMonthYear; an equity Fill 29 LastCapacity, 851 LastLiquidityInd, etc.).

**How the asset class of an order is determined**: from the instrument reference data when the symbol is known, otherwise from the inbound order's SecurityType (167) / CFICode (461); NewOrderMultileg (AB) is always Multileg. Asset classes: EQUITY, FUTURE, OPTION, MULTILEG, FIXED_INCOME, plus DEFAULT.

**Lookup order** for a report (first match wins):

1. Session override for (asset class, report type)
2. Profile template for (asset class, report type)
3. Profile template for (DEFAULT, report type)
4. Built-in default for the session's FIX version

So a profile only needs to define what is different for an asset class; anything not defined falls back to DEFAULT.

**Automation policy per asset class** too: the auto/manual settings in section 8 use the same lookup, so e.g. equities can be auto-acked while options stay manual.

The template editor shows a grid of report types × asset classes, marking which cells are inherited from DEFAULT, and the preview uses a sample order of the selected asset class.
