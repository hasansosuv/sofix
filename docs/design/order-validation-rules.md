# Configurable Order Validation Rules, draft 2026-10-04

Requirement (Ahmed, 2026-10-04, high priority): business validation is never hard-coded. Rules are configuration, grouped into rule sets (Retail, Institutional, Simulator, …) that are attached to sessions through profiles.

---

## 1. Three validation layers

| Layer                        | What                                                                                                                 | Configurable?                                                                                                                                                    |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1. FIX / session             | Checksum, seq nums, required tags, types, enums (QuickFIX/J + session dictionary)                                    | Via the session's dictionary only                                                                                                                                |
| 2. Order correlation / state | Duplicate ClOrdID, unknown tag 41, cancel on a filled order, pending replace already open, replace qty below CumQty… | Built-in and always on (a few have per-session policy switches, e.g. "accept non-latest tag 41"). These protect FIX correctness, so they are not editable rules. |
| 3. **Business rules**        | Everything in this document                                                                                          | **Fully configurable**                                                                                                                                           |

## 2. Rule definition

```yaml
rule:
  name: MAX_ORDER_QUANTITY
  description: "Order quantity must not exceed the account's per-order limit"
  appliesTo:
    messages: [NEW_ORDER, REPLACE] # D, AB, G (replace is checked on the new values)
    assetClasses: [EQUITY, FUTURE, OPTION] # empty = all
    sides: [] # empty = all
    orderTypes: [] # empty = all
  condition: "$order.qty <= $account.maxOrderQty" # must be TRUE to pass
  action: REJECT # REJECT | HOLD | WARN | ALERT
  reason: "Quantity ${order.qty} exceeds client limit ${account.maxOrderQty}"
  ordRejReason: 99 # tag 103 sent on the Reject ER (CxlRejReason 102 for replace)
  priority: 100 # lower runs first
  enabled: true
```

**Actions**

- `REJECT`: reject the order (ER Rejected, or OrderCancelReject for a replace) with `reason` in tag 58 and the configured 103/102 code. Respects the automation policy: AUTO_REJECT sends it immediately; MANUAL shows it to the trader with the failed rule pre-selected.
- `HOLD`: do not auto-ack even if the automation policy says AUTO; put the order in the trader's queue with the rule highlighted (e.g. large orders need a human).
- `WARN`: accept normally, but show a warning badge on the order in the blotter.
- `ALERT`: accept, and raise an alert (UI + metrics), e.g. unusual size for this client.

**Evaluation**: rules run in priority order; the first REJECT stops evaluation; HOLD, WARN and ALERT results are all collected. Every result records rule name + rule-set version on the order (shown in the lifecycle view).

## 3. Expressions

Same expression language as the execution report templates (one engine, one syntax, compiled once at activation, allocation-free at runtime).

Available data:

| Object          | Fields (examples)                                                                                                            |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `$order`        | qty, price, stopPx, side, ordType, tif, symbol, account, currency, notional (qty × price × multiplier), assetClass, `tag(n)` |
| `$account`      | exists, active, maxOrderQty, maxOrderNotional, dailyNotionalLimit, allowedAssetClasses, allowedSymbols, blockedSymbols       |
| `$client`       | id, type (RETAIL / INSTITUTIONAL), permissions                                                                               |
| `$instrument`   | exists, active, assetClass, tickSize, lotSize, multiplier, currency, refPrice, tradingHours                                  |
| `$session`      | senderCompId, targetCompId, profile                                                                                          |
| `$stats`        | account's open orders count, today's filled notional, today's order count (kept in memory by the engine)                     |
| `$now`, `$time` | current time, time of day                                                                                                    |

Functions: `in(x, list)`, `between(x, a, b)`, `abs`, `pct(a, b)` (percentage difference), `isMultiple(x, step)`, `exists(x)`, `and`/`or`/`not`, comparison operators.

## 4. Ahmed's rules expressed as configuration

```yaml
- name: QTY_POSITIVE
  condition: "$order.qty > 0"
  action: REJECT
  reason: "Quantity must be greater than zero"

- name: PRICE_POSITIVE
  appliesTo: { orderTypes: [LIMIT, STOP_LIMIT] }
  condition: "$order.price > 0"
  action: REJECT
  reason: "Price must be greater than zero"

- name: ACCOUNT_EXISTS
  condition: "$account.exists and $account.active"
  action: REJECT
  reason: "Unknown or inactive account ${order.account}"

- name: SYMBOL_ACTIVE
  condition: "$instrument.exists and $instrument.active"
  action: REJECT
  reason: "Symbol ${order.symbol} is not active"

- name: CLIENT_SYMBOL_ALLOWED
  condition: "not in($order.symbol, $account.blockedSymbols) and (empty($account.allowedSymbols) or in($order.symbol, $account.allowedSymbols))"
  action: REJECT
  reason: "Client is not allowed to trade ${order.symbol}"

- name: CLIENT_ASSET_CLASS_ALLOWED
  condition: "in($order.assetClass, $account.allowedAssetClasses)"
  action: REJECT
  reason: "Client cannot trade ${order.assetClass}"

- name: MAX_ORDER_QUANTITY
  condition: "$order.qty <= $account.maxOrderQty"
  action: REJECT
  reason: "Quantity exceeds client limit"

- name: PRICE_DEVIATION
  appliesTo: { orderTypes: [LIMIT] }
  condition: "abs(pct($order.price, $instrument.refPrice)) <= 10"
  action: REJECT
  reason: "Price deviates more than 10% from reference price"
```

Parameters can be pulled out of the expression (`threshold: 10`, referenced as `$param.threshold`) so ops can change the number without touching the condition.

## 5. Rule sets and profiles

- A **rule set** is a named, versioned list of rules: `Retail`, `Institutional`, `Simulator`.
- A rule set can **extend** another (`Retail extends Base`), overriding or disabling inherited rules, so common rules live in one place.
- A **broker profile** bundles everything the broker behaviour needs, each part a reusable named set:
  - validation rule set
  - execution report template set (per asset class)
  - automation policy (manual / auto per action)

```
Profile A (Retail)        → rules: Retail        → templates: Equities-4.4 → automation: manual ack, manual fill
Profile B (Institutional) → rules: Institutional → templates: Equities-4.4 → automation: auto ack, manual fill
Profile C (Simulator)     → rules: Simulator     → templates: Default      → automation: everything auto
```

- Sessions are assigned a profile. Later option: override the profile per client account.

## 6. Safety when changing rules

- **Validated on save**: expression parses, fields exist, types match, reason placeholders resolve.
- **Test cases per rule**: each rule can carry sample orders with expected outcome (pass / reject); they run on every save.
- **Impact preview**: before activation, run the new rule set against recent real orders and show how many would now be rejected / held, and which ones.
- **Versioned and audited** like all config (who, when, why, rollback); activation is an atomic in-memory swap, so an order is never checked against half-old, half-new rules.

## 7. Performance

Rules are compiled into a typed evaluator tree at activation (no parsing, no reflection, no boxing at runtime). Reference data (accounts, instruments, limits, reference prices) is held in memory and updated by snapshot swap. Target: a full rule set of ~20 rules evaluates in a few microseconds with zero allocation, verified by JMH benchmarks and the allocation budget test.

## 8. Reference data this needs

Validation is only as good as its data, so the broker needs maintained reference data, editable in the UI and importable via CSV:

- **Instruments**: symbol, asset class, active flag, tick size, lot size, multiplier, currency, reference price
- **Clients and accounts**: active flag, type, allowed asset classes, allowed / blocked symbols
- **Limits**: max order qty, max order notional, daily notional limit per account

Reference prices (for price deviation) in v1: imported or entered manually (e.g. previous close). Live market data can feed them later.
