# Test case certification between a buy side and a sell side (decided 2026-10-12)

Ahmed, 2026-10-12. Two SOFIX deployments, one `BUY_SIDE` and one `SELL_SIDE` (see
`application-scope-and-tenancy.md` §7), certify algo orders over a normal FIX session: the buy
side sends test-case orders, the sell side checks each one against the test case, answers over
FIX, and posts the detailed result back to the buy side as JSON.

## 1. Who does what

| | Buy side | Sell side |
|---|---|---|
| Upload a spec PDF → generate test cases (a **suite**) | ✓ | ✓ |
| Export a suite (file) / import a suite (file, e.g. received by email) | ✓ | ✓ |
| View suites, test cases, test case details | ✓ | ✓ |
| **Buy-Side Simulator**: choose a connected BUY_SIDE session, send test cases one by one or all (Auto), send one again | ✓ | |
| **Certification mode** (User Preferences): evaluate incoming orders against the user's active suite | | ✓ |
| Answer each D / G / F over FIX (Ack, Replaced, Canceled, or Reject / cancel reject) | | ✓ |
| Post the JSON result of each step to the buy side | | ✓ |
| Store runs and results; Test Case Result panel with history | ✓ | latest per order only (Order Lifecycle) |

No notification between the two sides: suites travel as files (email). Results travel over HTTP.

## 2. Suites

A suite is the test cases generated from one specification (e.g. `Broker5/test-cases.json`: 71
test cases, quantities 5–355, all unique within the suite) plus its ATDL, which declares the
**strategy identifier tag** (`strategyIdentifierTag="8031"`).

* Stored in the OEMS of each deployment: owner user, company (buy side), name, source file,
  imported / generated at, the test cases, the strategy identifier tag.
* Export = one JSON file (suite metadata, ATDL strategy tag, test cases). Import = the same file.
* Sell side: each user marks **one active suite** for certification mode. Quantities repeat
  across suites (each broker's copy uses 5–355), so only the active one is matched.

## 3. Which incoming orders are test-case orders (sell side)

An incoming 35=D is evaluated when **all** hold:

1. Its user (identity tag, e.g. 116) has certification mode on.
2. It carries the active suite's **strategy identifier tag** (8031).
3. Its **38 OrderQty** equals the quantity of a test case in that suite.

Otherwise it is a normal order (Manual / Auto handling). There is no 9999 for now.
Amends (G) and cancels (F) follow their order through 41: the *n*th accepted G is checked against
"Amendment *n*", the F against the Cancel step.

## 4. The check of one step

For each step (New Order, Amendment n, Cancel) the expected values are the step's parameter
table: `expected_input` as the wire value (`Target Auction=1` → `1`; a value without `=` as is),
`Directive: …` rows only require the tag to be present; plus 11 present, 38 = the test case
quantity, 49 / 56 = the session's CompIDs. Each check: tag, field, expected, received, passed,
note (as expected / different value / missing). The step passes when every check passes.

Answer: passed → Ack (D), Replaced (G), Canceled (F); failed → Reject (D, 39=8) or
OrderCancelReject (G, F) with 58 = the first failures, e.g. `8091 AuctionStyle expected 1,
received 0`.

## 5. The result sent to the buy side

After the FIX answer, the sell side POSTs one JSON per step to the **Test result URL** configured
on its FIX session (the buy side's OEMS), with the session's **access key**; retried while the
buy side is unreachable.

```json
{
  "suite": "Broker5", "testCaseId": "AUCTION_AMER_Broker5_TC_001", "step": "NEW_ORDER", "stepLabel": "New Order",
  "clOrdId": "ORD-1", "origClOrdId": null, "senderCompId": "CLIENT", "targetCompId": "EXEC",
  "result": "PASSED", "reason": "All 6 checks passed.",
  "checks": [ { "tag": "8091", "name": "AuctionStyle", "expected": "1", "received": "1", "passed": true, "note": "as expected" } ],
  "received": "8=FIX.4.4|35=D|…", "answer": "8=FIX.4.4|35=8|150=0|39=0|…",
  "answerType": "ACK", "evaluatedAt": "2026-10-12T10:00:00Z"
}
```

The buy side matches it to its run by session CompIDs and ClOrdID, stores it, and pushes it live
to the simulator (backend WebSocket). A test case's status: **Pending** until a result arrives,
**Failed** once any step fails, **Passed** when every step passed.

## 6. Buy side runs

A run = one sending of one test case: suite, test case, session, user, company, ClOrdID chain,
status, the step results. Sending a test case again creates a new run; the simulator shows the
latest run per test case, the history stays.

## 7. Limitations (now)

* Matching by quantity needs one active suite per sell-side user.
* No 9999: an order whose strategy tag and quantity match by accident is evaluated.
* Results go to a URL the sell side must reach (firewall); without it the buy side sees only the
  FIX answers.
