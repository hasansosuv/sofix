# Buy-side message templates, draft 2026-10-08

Requirement (Roma, 2026-10-08): the buy side needs templates for the messages it sends, the same way the broker side has ExecutionReport templates.

**Approach: one template engine for both sides.** The broker's ER templates (execution-report-templates.md) and these buy-side templates are the same mechanism: same tag classes, same expression functions (`$unique`, `$now`, …), same per-asset-class sets with DEFAULT fallback, same versioning, validation and preview. Only the message types and the source of the values differ. In code: one `MessageTemplateEngine`, used by `ExecutionReportBuilder` (sell side) and `OutboundOrderBuilder` (buy side).

---

## 1. Message types (one template each, per asset class)

| Template | Message | Notes |
|---|---|---|
| New Order | 35=D NewOrderSingle | Equity, future, option, FI |
| New Multileg Order | 35=AB NewOrderMultileg | Spreads, buy-write, NoLegs (555) group |
| Cancel | 35=F OrderCancelRequest | |
| Replace | 35=G OrderCancelReplaceRequest | |
| Multileg Replace | 35=AC MultilegOrderCancelReplace | |
| Order Status Request | 35=H | |
| Mass Cancel | 35=q OrderMassCancelRequest | Optional |
| Allocation | 35=J AllocationInstruction | Post-trade |
| Later | 35=E NewOrderList, 35=R QuoteRequest (RFQ, fixed income) | |

## 2. Tag classes on the buy side

| Kind | Who sets it | User can change? | Examples |
|---|---|---|---|
| **Engine (locked)** | The engine | Never | 11 ClOrdID (format configurable, uniqueness guaranteed by the engine), 41 OrigClOrdID, 37 OrderID on F/G (from the broker's ER), 60 TransactTime, 555 leg count, 70 AllocID, header tags |
| **Identity (locked)** | The engine, from the logged-in user | Never | 116 OnBehalfOfSubID = user's email or chosen alias (tag configurable per session). This is what lets the returning message be matched to the user (test-routing-by-user-tag.md, flow A). |
| **Carried from the order (locked)** | Current version of our order | Never on Cancel; on Replace only the fields the template marks *amendable* | 55, 54, 1, 167, 200/541/201/202 on F and G |
| **Order ticket input** | The user on the order ticket in the UI | Yes, within the template's rules | 55 Symbol, 54 Side, 38 OrderQty, 40 OrdType, 44 Price, 99 StopPx, 59 TimeInForce, 126 ExpireTime, 1 Account, legs (600-624) |
| **Template value** | Fixed value or expression | Yes, by template editors | 21 HandlInst = 1, 100 ExDestination, 528 OrderCapacity, 15 Currency, 18 ExecInst, custom tags |
| **Algo parameters** | From the session's **ATDL** file for the chosen strategy | Yes, per the ATDL rules | 847 TargetStrategy, strategy params (957 group or custom tags) |

Precedence for one tag is the same as on the sell side: locked > user input > template value > profile default > not sent.

## 3. The order ticket is generated from the template

* For each asset class the template lists which ticket fields appear, their labels, required flags, defaults, allowed values (dropdowns), and validation. Choosing "Option" shows put/call, strike, expiry, open/close; choosing "Multileg" shows a leg grid; choosing an algo strategy renders its ATDL parameters.
* **Amendable fields** on Replace come from the template (typically qty, price, stop price, TIF, expire time).
* **Extra tags** (optional, permission-controlled): an "Additional tags" grid on the ticket lets a user add any tag=value not covered by the template. Useful for certification testing. Locked tags can never be added or overridden this way.
* **Saved order presets** per user (private / group / public, same as test cases): a filled-in ticket saved by name, e.g. "AAPL 100 limit DAY", for repeat use in testing.

## 4. Pre-trade checks

Before sending, the order goes through the configurable rule engine (order-validation-rules.md) with a buy-side rule set: e.g. max quantity, price collar, allowed accounts and symbols, session must be logged on. REJECT stops the order in the UI with the rule's reason; WARN asks the user to confirm.

## 5. Profiles

A **buy-side profile** bundles: template set (per asset class) + pre-trade rule set + identity tag settings + ClOrdID format + ATDL files. Sessions with role BUY_SIDE point to a buy-side profile and can override single templates, exactly as sell-side sessions point to a broker profile.

## 6. Inbound side

ExecutionReports and cancel rejects coming back are processed by `ExecutionReportProcessor` (fills, cancels, rejects, ExecID dedup, busts/corrections). No templates are needed for inbound messages; checking whether the counterparty's responses are correct is the job of test cases (UAT).

## 7. In the outline

* `MessageTemplateEngine`: placeholder interface, shared by both sides.
* `OutboundOrderBuilder`: default `DefaultOutboundOrderBuilder` (standard tags per FIX version, no templates) when the buy-side layer is built; `TemplateOutboundOrderBuilder` placeholder.
* `OrderTicketDefinitionProvider`: placeholder; later serves the ticket layout (from templates + ATDL) to the UI.
