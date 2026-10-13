# Feature: certification mode (test cases for execution) and User Preferences

Status: built 2026-10-13. sofix-oems `9e990fb` `7bd63b7` `3c04e41`; sofix-ui-be `69015d3`;
sofix-ui-fe `83baa2a` `d335c00` (+ the Session Business Configuration and blotter commits after
it). Design: `docs/design/test-case-certification.md`.

## 1. What the users do

**Sell side (the broker)**

1. **User Preferences** (menu Settings, or the user menu): every user has it.
   - **Load test case for execution**: switching it on opens a dialog listing the user's test
     suites with their test cases. **Load and switch on** makes the chosen suite the user's
     active suite and switches test cases on. Switching it off takes effect at once.
   - **Broker actions**: how each incoming message of the user's orders is answered, Manual (a
     trader) or Auto with a lifecycle (Pending, ack / accept, fills). It moved here from Session
     Business Configuration: it is per user.
2. **Session Business Configuration** (Edit right, given by an administrator):
   - **User resolution tag**: the tag naming the user of each incoming order (default 116; e.g.
     57 TargetSubID). The order is shown to that user and answered per their preferences.
   - **Certification results**: the **Test result URL** (the client's buy-side OEMS,
     `http://<buy-host>:<port>/api/certification-results`) and the **access key** agreed with it.

**Buy side (the client)**

1. **Session Business Configuration** for the session to the broker:
   - **User identity tag**: the tag carrying the user on every message (default 116; set the
     tag the broker reads, e.g. 57).
   - **Result access key**: the same key as on the broker's side.
   - The strategy tags the test cases expect (e.g. 8031 = AUCTION) go into the template as
     custom fixed tags, or on the ticket when templates offer them.
2. Send orders with a test case's quantity. The **Order Blotter** shows each order's latest
   result (test case, step, PASSED / FAILED; reason and failed checks as tooltip), and the order's
   events list each result.

## 2. Flow

```mermaid
sequenceDiagram
  participant BUY as Buy-side OEMS
  participant SELL as Sell-side OEMS
  participant DB as Sell DB (suites, preferences)
  BUY->>SELL: 35=D 57=riya 8031=AUCTION 38=5 … (FIX)
  SELL->>SELL: user by tag 57 → riya; test cases on?
  SELL->>DB: riya's active suite
  SELL->>SELL: suite tag 8031 present, 38=5 → TC_001; check the New Order step
  SELL-->>BUY: 35=8 ack (passed) or reject with 58 = first failures (FIX)
  SELL->>BUY: POST /api/certification-results, X-Access-Key, JSON (checks, received, answer)
  BUY->>BUY: session by CompIDs + key; order by ClOrdID; keep result; push to the blotter
```

Replaces follow the order through 41: the n-th replace is checked against Amendment n (only
replaces accepted before count); the cancel against the Cancel step. Passed: Replaced / Canceled;
failed: OrderCancelReject with the failures in 58.

## 3. Data

| Data | Where |
|---|---|
| Suites, each user's active suite | sell OEMS DB: `test_suite`, `user_active_suite` |
| Test cases on, broker actions | sell OEMS DB: `user_preference`, `user_action_mode` |
| User resolution tag, Test result URL and key | sell OEMS DB: `session_business_config` (V9 adds URL and key) |
| User identity tag, result access key | buy OEMS DB: `buy_session_setting` (V8, V9) |
| Results | sell: logged and published (`test-result` event); buy: on the order, in memory |

Endpoints: backend `GET|PUT /api/preferences` (the caller's own, sell side) → OEMS
`/api/users/{id}/preferences`; `PUT /api/test-suites/active`; sell OEMS
`PUT /api/sessions/{id}/business-config` (`testResultUrl`, `testResultKey`); buy OEMS
`PUT /api/buy-session-templates/{session}/settings` (`identityTag`, `resultAccessKey`) and
`POST /api/certification-results` (called by the broker's OEMS directly).

## 4. Enforced and tested

| Rule | Where | Test |
|---|---|---|
| Test-case order = active suite + strategy tag + test case quantity | `CertificationService`, `TestCaseMatcher` | `CertificationServiceTest`, `OrderServiceTest` |
| Step checks, amendment numbering (accepted only) | `TestCaseEvaluator`, `CertificationService` | `CertificationServiceTest` |
| FIX answer per verdict, 58 = failures | `OrderService.certify` | `OrderServiceTest` |
| Result POST with key, retries | `HttpTestResultSender` | manual check 2026-10-13 |
| URL http(s), key 8–200, key kept when left out | `SessionBusinessConfigValidator` | `SessionBusinessConfigValidatorTest` |
| Buy side refuses unknown session / wrong key (401), unknown ClOrdID (404) | `CertificationResultController` | `BuyOrderApiTest` |
| Identity tag 1–99999, not a header or order-data tag | `IdentityTags` | `TemplateEditsTest`, `BuyOrderApiTest` |
| Whole loop, user in 57, passed / failed / cancel / no match | two OEMS instances | manual check 2026-10-13 (Broker5 TC_001, TC_002, TC_003) |

## 5. Known limitations

1. Buy-side results live with the order in memory: an OEMS restart loses them. Runs and result
   history per test case (the simulator's Test Case Result) come with the simulator step.
2. The sell side shows results in its logs and the `test-result` event only; Order Lifecycle
   does not show the checks yet (the actor is `TEST:<user>`).
3. A result the buy side never receives (unreachable for ~9 minutes) is dropped after the last
   retry and logged as an error on the sell side.
4. The active suite is read from the database for each new order of a user in certification
   mode (not cached).
5. 49 / 56 are not checked (QuickFIX/J already ties them to the session).
6. The earlier tag-9999 test cases (`PUT /api/users/{id}/test-run`, `UserTestCase`,
   `TestCaseChecker`) are no longer used by the order flow; they are left in place until removed.
