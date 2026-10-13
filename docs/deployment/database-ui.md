# Database UI (pgAdmin)

pgAdmin 4 runs from its own compose file, [`compose.db-ui.yaml`](../../compose.db-ui.yaml), next to
the main one. It is independent of the stacks: start and stop it any time; it does not touch the
databases' containers.

## Start, open, stop

From the workspace folder:

```bash
docker compose -f compose.db-ui.yaml up -d      # start (first time: pulls dpage/pgadmin4)
open http://localhost:5050                      # the UI; no pgAdmin sign-in (desktop mode)
docker compose -f compose.db-ui.yaml down       # stop; saved passwords and settings stay
docker compose -f compose.db-ui.yaml down -v    # stop and forget pgAdmin's settings
```

## The servers

Both are listed already, in the group **SOFIX** (from [`docker/pgadmin/servers.json`](../../docker/pgadmin/servers.json)):

| Server | Address (from pgAdmin) | Databases | User / password |
|---|---|---|---|
| Sell side (Docker stack) | `host.docker.internal:5433` | `sofix` (backend: users, rights, layouts…), `oems` (OEMS: sessions, templates, suites…) | `sofix` / `sofix` |
| Buy side (project `sofix-buy`) | `host.docker.internal:5533` | `sofix`, `oems` | `sofix` / `sofix` |

Click a server, enter the password (tick "Save password"), then expand Databases → `oems` or
`sofix` → Schemas → public → Tables. Right-click a table → View/Edit Data, or Tools → Query Tool
for SQL.

A server shows a red mark until you connect, and an error when its PostgreSQL is not running
(start it: `docker compose up -d` for the sell side,
`docker compose --env-file docker/buy-side-db.env up -d postgres db-init` for the buy side).

The database owners `sofix` (backend database) and `oems` (OEMS database) can be used too
(passwords `sofix` and `oems` by default); `sofix` is also the server's superuser and sees both.
If `.env` changes `POSTGRES_SUPERUSER` / `POSTGRES_SUPERUSER_PASSWORD`, use those.

## Settings

Every setting has a default; set them in the shell or a `.env` file (the same one as the main
stack is read):

| Variable | Default | What |
|---|---|---|
| `PGADMIN_HOST_PORT` | `5050` | Port of the UI on this machine |
| `PGADMIN_BIND` | `127.0.0.1` | `0.0.0.0` to reach it from other machines (then set `PGADMIN_CONFIG_SERVER_MODE` to `True` in the file for a sign-in) |
| `PGADMIN_VERSION` | `9` | Image tag of `dpage/pgadmin4` |
| `PGADMIN_EMAIL` / `PGADMIN_PASSWORD` | `admin@sofix.dev` / `sofix-admin` | Required by the image; used only in server mode |
| `DB_UI_PROJECT_NAME` | `sofix-db-ui` | Compose project name |
| `PGADMIN_VOLUME` | `sofix-db-ui_pgadmin-data` | Volume with pgAdmin's settings and saved passwords |

## Careful

Changing data by hand bypasses the applications: the OEMS keeps sessions, templates and settings in
memory, so a change made here is seen after it restarts (or not at all if it saves over it). Prefer
reading; for changes use the app.
