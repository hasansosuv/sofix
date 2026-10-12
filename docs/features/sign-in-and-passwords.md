# Feature: sign-in and passwords (SSO off)

Status: 2026-10-12. sofix-ui-be `8990c5e` `e1bcf32` `d0c07b0` `30f0cca`; sofix-ui-fe `6732699`
`ef4a99d`; workspace `fbca107`.

## 1. Rules

| Rule | Where |
|---|---|
| Sign-in is by **password only**: username or email (any case) + password. SSO is off: `OIDC_ISSUER` is empty in compose, so `/api/auth/config` says `sso.enabled: false` and the app hides the SSO button. A real OIDC provider can be turned on with the `OIDC_*` variables (code kept) | sofix-ui-be `auth.js`, `compose.yaml` |
| A password has 8–200 characters and must **differ from the current one** (400 otherwise) | `auth.js setPassword` |
| Setting a password **ends the user's open sessions** (also your own) | `setPassword` |
| 5 failed sign-ins for the same name within 15 min **lock** that name for 15 min (429). The lock is in the backend's memory, per spelling (`operator` and `operator@…` count apart); a restart clears it | `auth.js login` |
| Every refused sign-in is **logged** with its reason: no such user, the user has no password, wrong password (n of 5), locked, inactive account. Never the password. The browser gets one message for an unknown user and a wrong password | `auth.js refused` |
| **Recovery** from the server: `docker compose exec backend node src/set-password.js <username or email>` asks twice without echo (piped: one line), same rules | `src/set-password.js` |
| The Set Password dialog and the new-user form have an **eye button** on each password field | sofix-ui-fe `PasswordToggle` |
| The first admin gets `INITIAL_ADMIN_PASSWORD` (default `sofix-admin`) only when nobody has a password yet | `seedFirstPassword` |

## 2. Data flow

```mermaid
sequenceDiagram
  participant UI as Login page / Users → Set Password
  participant BE as sofix-ui-be
  participant DB as ui DB (user_credential, app_session)
  UI->>BE: POST /api/users/1/password { password }
  BE->>DB: read current hash; same → 400
  BE->>DB: upsert scrypt hash; delete the user's sessions
  UI->>BE: POST /api/auth/login { login, password }
  BE->>BE: lock check (memory) → 429 + log
  BE->>DB: user by username or email + hash
  BE->>BE: wrong → count failure, log reason, 401; inactive → log, 403
  BE->>DB: new session (token hashed)
  BE-->>UI: { token, user, access }
```

Passwords are stored as scrypt hashes (N 16384, r 8, p 1, 16-byte salt) in `user_credential`.

## 3. Known limitations

1. The failure counter and lock live in memory: they reset on restart and are not shared if
   several backends run.
2. The only password rule is length (8–200) and "not the same as now"; no complexity, history or
   expiry.
3. Password changes are in the backend log only (`user N password set`), not in an audit table.
4. Recovery trusts access to the server (or the database URL); anyone with that can set any
   password.
5. With SSO off, a user created without a password cannot sign in until one is set.

## 4. How to try it

1. Users → Demo Operator → Set Password; type a password, click the eye to check it, save.
2. Sign out, sign in with `operator` and the new password.
3. Type a wrong password: the backend log shows `sign-in refused for "operator": wrong password (1 of 5 in 15 min)`.
