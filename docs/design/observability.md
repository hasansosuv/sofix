# Observability from day 1, draft 2026-10-08

Requirement (Ahmed, 2026-10-08): production application from day 1, with detailed metrics and support for Prometheus, Grafana, Kibana and whatever else is needed for the different kinds of logging information.

Builds on design doc sections 16 (logging) and 18 (metrics).

---

## 1. Stack

| Signal             | Produced by                                                                                                                                                     | Collected / stored by                               | Viewed in                                                               |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- | ----------------------------------------------------------------------- |
| **Metrics**        | sofix-oems: Micrometer (`/actuator/prometheus`). Node BFF: `prom-client` (`/metrics`). PostgreSQL: postgres_exporter. Hosts/containers: node_exporter, cAdvisor | **Prometheus** (scrapes every 5-15 s)               | **Grafana** dashboards; live subset in the sofix UI                     |
| **Alerts**         | Prometheus alert rules                                                                                                                                          | **Alertmanager** → email / Slack / Teams            | Grafana, sofix UI alert banner                                          |
| **Logs**           | sofix-oems: Log4j2 JSON in **ECS format** (Elastic Common Schema, built into Log4j2's JsonTemplateLayout). Node BFF: `pino` JSON in ECS format                  | **Filebeat** ships log files → **Elasticsearch**    | **Kibana** (search, dashboards, saved queries)                          |
| **Traces**         | OpenTelemetry: Java agent / Micrometer Tracing in sofix-oems, OTel SDK in Node BFF, propagated from the browser request                                         | **OpenTelemetry Collector** → **Tempo** (or Jaeger) | Grafana (trace view, jump from a log line or metric spike to the trace) |
| **Business audit** | Orders, FIX messages, session and config changes                                                                                                                | PostgreSQL (not logs)                               | sofix UI lifecycle / audit views                                        |

One `traceId` ties them together: it is on every log line, on traces, and shown in the UI on any error, so one id finds the browser click, the BFF call, the engine processing and the FIX messages.

Because logs are ECS JSON, Grafana Loki or OpenSearch can replace Elasticsearch/Kibana later without changing the application.

## 2. What is collected

**Metrics** (full list in design doc section 18):

- FIX sessions: status, seq nums, messages in/out by MsgType, resends, rejects, heartbeat staleness
- Orders: received / acked / rejected (by rule) / filled / cancelled, pending trader actions and oldest age, auto vs manual actions
- Test execution (UAT): runs started / passed / failed, messages per user, unattributed messages
- Latency histograms: FIX in → response out, UI click → ExecutionReport, DB writer lag
- JVM: heap, GC pauses, allocation rate, threads; Node: event loop lag, heap; PostgreSQL: connections, slow queries, replication, table sizes
- BFF: HTTP request rates/latency/errors per endpoint, WebSocket clients, event fan-out lag

Naming convention: `sofix_<area>_<what>_<unit>` with low-cardinality labels only (`session`, `environment`, `direction`, `msg_type`, `rule`). Never order ids, ClOrdIDs or free text as labels (those go in logs), to keep Prometheus fast.

**Logs** (index per stream in Elasticsearch, 1-year retention for audit-relevant streams, shorter for debug):

- `sofix-app`, `sofix-error`, `sofix-fix-session`, `sofix-fix-messages` (optional per session), `sofix-audit`, `sofix-perf`, `sofix-bff`

## 3. Dashboards and alerts as code

Everything lives in the repository under `ops/observability/` and is provisioned automatically, so every environment gets the same view:

- `prometheus/` scrape config + alert rules
- `alertmanager/` routing (who gets which alert)
- `grafana/provisioning/` data sources + dashboards (JSON):
  - **FIX Sessions** (one row per session, UAT/PROD filter)
  - **Order Flow** (throughput, rejects by rule, pending trader actions)
  - **Latency** (p50/p99/p99.9 histograms)
  - **Test Execution** (UAT)
  - **JVM / Node / PostgreSQL / Host**
- `kibana/` saved searches and dashboards (errors by code, session events, audit trail)

Starter alert rules: session down during its schedule, sequence gap / resend storm, pending trader action older than N seconds, engine p99 above target, DB writer lag, error rate spike, disk nearly full, JVM GC pause above threshold.

## 4. Running it

- `docker compose --profile observability up` starts Prometheus, Alertmanager, Grafana, Elasticsearch, Kibana, Filebeat, OTel Collector and Tempo next to the app for local and UAT use.
- In production the same configs are deployed to the shared monitoring stack (or a managed one: Grafana Cloud / Elastic Cloud).
- Health endpoints for orchestration: liveness and readiness (readiness waits for DB, config load and journal replay).

## 5. Performance guard

Metrics on the hot path are plain counters/histograms owned by the engine thread and sampled by a metrics thread (no locks, no allocation per message). Tracing is applied to UI commands and sampled for FIX message processing, never forcing a span allocation for every message.
