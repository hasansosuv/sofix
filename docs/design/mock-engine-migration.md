# Moving the Mock Engine into sofix-oems (plan, draft 2026-10-08)

Status: **proposed, not started.** The decisions at the end are open.

`sofix-mock-backend` (the "Mock Engine", Node.js, about 1,760 lines) stands in for this
service today. `sofix-ui-be` (the Node BFF) forwards order, certification and test-run calls
to it, and the Angular app talks only to `sofix-ui-be`. The goal is to move the Mock
Engine's functionality here, following `CLAUDE.md` and `skeleton-outline.md`:

- Each capability becomes an interface (port) with a default implementation, chosen by
  `sofix.extensions.*` config.
- Only `oems-fix-qfj` imports `quickfix.*`.
- The HTTP/JSON contract stays the same, so `sofix-ui-be` only changes its target URL and
  the Angular app does not change.

## What moves, and where

| Mock Engine file | What it does | Module | Proposed Java |
|---|---|---|---|
| `strategies.js` | 15 built-in strategies and the combined ATDL; the source of the 71 test cases | `oems-application` (default behind a port) | `SpecificationConverter` port with `BuiltInStrategiesConverter` as the default; a real PDF→ATDL converter later |
| `certification.js` | create a certification; stream the spec "conversion" as NDJSON | `oems-api`, `oems-application` | `CertificationController`: `POST /api/certifications`, `POST /api/certifications/{id}/specification` (streamed). `CertificationService` |
| `test-cases.js` | parse ATDL; generate test cases (default values, required only, dropdowns via amendments, numeric ranges, times, checkboxes) | `oems-domain` (model, ATDL reader), `oems-application` (generator) | `TestCase`, `TestCaseStep`, `TestCaseParameter`, `AtdlStrategy`, `AtdlReader`; `TestCaseGenerator` port with `AtdlTestCaseGenerator` as the default; `POST /api/certifications/{id}/test-cases` |
| `state.js` | in-memory orders with their event histories; snapshot | `oems-domain`, `oems-application` | `Order`, `OrderEvent`; `OrderBook` port with an in-memory default (JDBC later); `GET /api/orders` |
| `commands.js` | ack, reject, cancel-accept, cancel-reject → ExecutionReport / OrderCancelReject | `oems-domain` (state rules), `oems-application` | `OrderCommandService`; `POST /api/orders/{clOrdId}/{command}` |
| `message-manipulator.js` | changes or removes some checked tag values in a share of runs (never 8, 11, 35, 49, 56, 9999) | `oems-application` | `MessageManipulator` port: `NoOpMessageManipulator` by default, `RandomMessageManipulator` when enabled, rate `sofix.test-runs.manipulation-rate` (0.3) |
| `test-case-evaluator.js` | expected vs received checks → PASSED/FAILED with reasons, correct/wrong, FIX sent/received | `oems-domain` (pure logic) | `TestCaseEvaluator`, `TestCaseResult`, `TestCheck` |
| `receiveTestRun` (`server.js`) | check session and ClOrdID, record the order, manipulate, evaluate, answer the result | `oems-application`, `oems-api` | `TestRunService`, `TestRunController`: `POST /api/test-runs`. It checks against the OEMS's own sessions. |
| `/ws` + `publish` (`server.js`) | pushes order events to sofix-ui-be | `oems-api` | order events on the OEMS event stream (decision 1) |
| `test-api.js` | e2e controls: reset, inject 35=D / 35=F, drop connections | `oems-api` | `TestControlController`, `@Profile("e2e")` |
| `order-feed.js` | random order generator (off by default) | `oems-application` | `RandomOrderFeed` job, `sofix.jobs.random-order-feed.enabled=false` |
| env timings (`ENGINE_DELAY_MS`, `SPEC_CHUNK_MS`, `TEST_CASES_DELAY_MS`, `MANIPULATION_RATE`) | delays and rates | `oems-app` | `@ConfigurationProperties` in `application.yml` |

## What does not move

- `sessions.js` (the Mock Engine's list of valid sessions) exists only because the mock is
  separate. The OEMS already owns the sessions. Drop it, with `sofix-ui-be`'s
  `registerWithEngine` / `registerStartedSessions`.
- `fix-log.js` (SOH logs to `inbound.log` / `outbound.log`) is replaced by the OEMS's Log4j2
  per-session logs and the message journal.
- `oidc.js` (mock SSO identity provider) is login, not the FIX engine. Keep it as a
  development-only IdP, or replace it with Keycloak (decision 4).

## Changes in sofix-ui-be afterwards

- `forwardToEngine` / `engineRequest` target `OEMS_URL` instead of `ENGINE_URL`; paths and
  JSON are unchanged.
- `startEngineLink` (WebSocket to the Mock Engine) is replaced by the OEMS event stream for
  order events, as `startOemsSessionLink` already does for sessions.
- `compose.yaml`: the `engine` service is removed, or kept only as the IdP.

## Order of work (small commits, `./mvnw verify` green at each)

1. Test case domain model, ATDL reader and generator, with tests. The built-in strategies must
   still give 71 test cases (`AUCTION_AMER` 4, `NAVIGATOR_AMER` 6, `SONAR_EMEA` 6, …).
2. Certification endpoints: the streamed spec conversion and test case generation.
3. Orders: order book, recording incoming orders, commands, snapshot, order events.
4. Test runs: manipulator, evaluator, `POST /api/test-runs`.
5. e2e control API under the `e2e` profile.
6. Switch `sofix-ui-be` to the OEMS; update `compose.yaml`.
7. Retire `sofix-mock-backend`, keeping the IdP if decided.

## Open decisions (recommendation first)

1. **Event stream to sofix-ui-be:** add order events to the existing Server-Sent Events
   stream (`GET /api/sessions/events`, generalised), and move to a WebSocket later if needed.
   The alternative is the design doc's single WebSocket now.
2. **Data sofix-ui-be holds today:** `broker_test_case`, `test_run`, `certification`,
   `order_template` and `broker_spec` belong to the OEMS by design, with `owner_user_id` and
   `visibility`. Move them as a separate step after this one.
3. **Order storage:** in memory first, as the mock does; the JDBC order book as its own
   layer.
4. **Mock SSO:** keep a development-only IdP (the existing `oidc.js`, about 170 lines), or
   switch to Keycloak.

Reference: `sofix-ui-fe/docs/developer/test-case-storage.md` describes how test cases are
stored, run and evaluated today.
