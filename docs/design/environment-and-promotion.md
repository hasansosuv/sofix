# Environments and promoting configuration from UAT to PROD, draft 2026-10-08

Question (Ahmed, 2026-10-08): how do we manage environments, and how do we copy/promote session configuration from UAT to PROD?

---

## 1. How environments are run

### Option A: one deployment, sessions tagged UAT or PROD

One sofix-oems instance and one database hold both UAT and PROD sessions; the session's `environment` field tells them apart.

- Pros: simplest to run; promotion is a copy inside one database.
- Cons: a UAT test storm, a bad UAT config or a bug in a new release can slow or break PROD; one set of credentials and one network zone for both; you cannot deploy a new version to UAT first.

### Option B (recommended): separate deployments per environment

The same build is deployed twice: a **UAT stack** and a **PROD stack**, each with its own sofix-oems, Node BFF, PostgreSQL databases, secrets, network zone and monitoring labels.

- Each instance declares its environment at startup (`sofix.environment: UAT|PROD`) and only accepts sessions of that environment. The UAT-only features (Run test cases) are refused by the PROD instance itself.
- New releases go to UAT first, then to PROD.
- The UI can either be deployed per environment or have an environment switcher at the top (the BFF connects to both engines); a coloured banner always shows which environment you are in (e.g. red for PROD).
- Pros: PROD is isolated from testing load, test data and UAT mistakes; standard practice in trading firms; auditors expect it.
- Cons: two stacks to run (same Docker images and configs, so the extra work is small), and promotion needs an export/import step (below).

The session `environment` field stays either way, so we can start with option A in development and move to B without code changes.

## 2. Promoting configuration (works with A or B)

### What gets promoted: a config bundle

A **config bundle** is a versioned JSON/YAML document containing the selected sessions plus everything they reference:

- FIX settings and business settings
- the profiles they use: template sets (per asset class), validation rule sets, handling-mode policy
- user-identification settings, allowed messages and asset classes, ATDL files, reference-data mappings

Each item carries its version and a checksum, so PROD knows exactly what it received.

### Environment-specific values are never copied blindly

Some values must differ between UAT and PROD. They are marked **environment-specific** and handled separately:

| Never copied (PROD keeps its own)                   | Copied, but shown for confirmation                               |
| --------------------------------------------------- | ---------------------------------------------------------------- |
| Passwords (554), TLS certificates and other secrets | Host / port, CompIDs (often differ, e.g. `SOFIX_UAT` vs `SOFIX`) |
| Run test cases (always off in PROD)                 | Schedules, throttle limits                                       |
|                                                     | Handling mode (UAT may be all-auto, PROD manual)                 |

On first promotion of a session, PROD asks for the environment-specific values; on later promotions it keeps them.

### Promotion flow

1. In UAT, select sessions (or a whole profile) → **Promote to PROD**.
2. The bundle is created and sent to PROD (option B: PROD's import API, authenticated service-to-service; or download/upload a file if the networks are separated).
3. PROD shows a **diff**: new items, changed fields, removed items, environment-specific values to fill in.
4. **Four-eyes approval**: a second user with the `prod.config.approve` permission approves (the requester cannot approve their own change).
5. PROD applies it as a **new version** of each item (business settings live; FIX settings at the next session restart or a scheduled time), fully audited on both sides.
6. **Rollback**: one click re-activates the previous version.

Each PROD item remembers "promoted from UAT session X, version 12", so the UI can show **drift**: "UAT has 3 changes not yet in PROD".

### Later: Git (already decided for after v1)

The same bundle format is written to a Git repository; the pull-request review replaces the in-app approval, and a merge triggers the import into PROD. No change to the bundle or import logic is needed.

## 3. In the outline

- `sofix.environment` setting, logged at startup, shown in metrics labels and the UI banner.
- `ConfigBundleExporter` / `ConfigBundleImporter`: **placeholders**.
- `ConfigApprovalService`: **placeholder** (four-eyes approval).
