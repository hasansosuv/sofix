# Parent and child orders (broker side), draft 2026-10-10

Question (Roma, 2026-10-10): when an inbound order appears on the blotter, should it always be created as a parent order, or stay a plain order until a user right-clicks "Create child order" (which then makes it a parent), or should this be a user setting? Children are used to slice the order and send it to the next broker, or in certification mode to send partial fills / fills to the client.

---

## 1. Recommendation: one model, no modes

Internally **every inbound client order is the same thing: a client order that can have zero or more children.** "Parent" is not a separate kind of order or a flag that has to be switched; an order *is* a parent as soon as it has at least one child.

* No configuration needed and nothing to keep in sync between two modes: the engine always stores the client order the same way, and creating a child never converts or copies anything.
* The blotter shows one row per client order. The row gets an expand arrow and parent columns (working in children, unplaced quantity) only once a child exists.
* User settings only change **display**, not the data: "show children nested under the parent / in a separate child blotter", "open the slicing ticket automatically on new orders".

So the user gets exactly what they asked for (the order becomes a parent the moment they create a child) without the engine having two code paths.

## 2. Kinds of order

| Kind | What it is | Who it talks to |
|---|---|---|
| `CLIENT` | The order received from the client over FIX (35=D/AB). The root of the tree. | Client session: all ERs (35=8) go to the client from this order. |
| `STREET` child | A slice sent out to the next broker over a buy-side session (35=D/F/G). | Next broker. Its fills roll up into the client order. **Buy-side layer (later)**; placeholder in the outline. |
| `MANUAL` child | A slice worked by hand on the desk, not sent anywhere. The trader enters fills on it from the UI (price, qty, LastMkt…). | Nobody directly; its fills roll up into the client order. Covers certification / simulation and care orders filled by phone or another system. |

Fills can also be entered **directly on the client order** without any child (today's "manual fill" action). That stays the simplest path and needs no child at all.

## 3. Rules

**Quantities**
* Placed quantity = sum of open quantity of working children. Unplaced = client LeavesQty − placed.
* Creating or amending a child above the unplaced quantity: configurable `REJECT` (default) or `WARN` (over-placement allowed with a warning).

**Fills roll up**
* Client order CumQty = direct fills + all child fills; AvgPx recalculated; LeavesQty = OrderQty − CumQty.
* Each child fill produces a client ER (partial fill / fill) with LastQty / LastPx / LastMkt from that fill. Whether that ER is sent automatically or waits for the trader is the existing per-action manual/auto setting (execution-report-templates.md section 8), e.g. "auto-forward child fills" or "trader releases fills".
* Option (later): aggregate several child fills into one client ER (by time window or at the end), configurable per profile.

**Client cancels or replaces the parent**
* No working children: handled as today.
* Working children: the client order goes to PendingCancel / PendingReplace; children are cancelled or reduced first (manual or auto per policy `parentCancelPolicy: CANCEL_CHILDREN_THEN_PARENT | WAIT_FOR_TRADER`), then the client gets the cancel / replace ER. A replace that reduces quantity below what is already filled + working is rejected (OrderCancelReject 9) unless children are cancelled.

**Unsolicited events**
* Trader cancels a child: unplaced quantity goes back up, nothing goes to the client.
* Done for day / expiry on the client order: working children are cancelled first.

**States**
* The client order keeps the FIX OrdStatus state machine already designed (what the client sees). Children have their own state machine instance of the same table. Parent "working" information (placed, unplaced, children count) is derived, not a separate state.

## 4. Data model

```
order
  order_id, tenant_id, client_id, owner_user_id
  kind            CLIENT | STREET | MANUAL
  parent_order_id NULL for CLIENT
  root_order_id   the CLIENT order of the tree (fast lookups)
  ... existing fields (ClOrdID chain, side, qty, price, OrdStatus, CumQty, AvgPx, LeavesQty)
fill
  fill_id, order_id (the order it was entered on), root_order_id, qty, px, last_mkt, source (DIRECT | CHILD), ...
```

v1: one level of children (client → child). Grandchildren (slicing a child again) can be added later; the model already allows it through parent_order_id.

## 5. Outline changes

| Interface | Default | Placeholder |
|---|---|---|
| `ChildOrderService` | Create / amend / cancel `MANUAL` children from the UI, with the placement check | `STREET` children sent to the next broker (buy-side layer) |
| `FillRollupService` | Roll child fills into the client order (CumQty, AvgPx, LeavesQty) and hand the client ER to the action-mode check | Aggregated client ERs |
| `ParentCancelPolicy` | `WAIT_FOR_TRADER` | `CANCEL_CHILDREN_THEN_PARENT` |
| `PlacementCheck` | `REJECT` over-placement | `WARN` |

Domain: `OrderKind` (CLIENT, STREET, MANUAL), `Order.parentOrderId`, `Order.rootOrderId`, `Fill.source`.

## 6. How hard is this

Supporting "both" is not harder than supporting one, because there is only one model: a client order with an optional list of children. The real work is in the rules of section 3 (roll-up, placement check, cancel / replace with working children), and those are needed as soon as children exist at all. Recommended build order: direct fills on the client order first (broker order flow layer), then `MANUAL` children, then `STREET` children with the buy side.
