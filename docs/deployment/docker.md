# Running SOFIX with Docker

One `compose.yaml` (in the workspace folder) builds and runs the whole platform. Every setting
is an environment variable with a default; put the ones you change in a `.env` file next to
`compose.yaml` (`.env.example` lists them all, commented out).

```bash
cd sofix                       # the workspace folder
cp .env.example .env           # once; edit what you need
docker compose up -d --build   # build the three images and start everything
```

Open `http://localhost:8080` (or `PUBLIC_URL`) and sign in as `operator` with
`INITIAL_ADMIN_PASSWORD` (default `sofix-admin`); change it in Users.

## 1. What runs

```mermaid
flowchart LR
  B[Browser] -- ":8080 (UI_HOST_PORT)" --> UI
  subgraph Docker[docker compose project: sofix]
    UI[ui<br/>nginx + the app<br/>sofix-ui-fe] -- "/api, /ws" --> BE[backend<br/>sofix-ui-be :8090]
    BE -- "REST + SSE" --> OEMS[oems<br/>sofix-oems :8095]
    BE --> PG[(postgres<br/>database sofix)]
    OEMS --> PG2[(postgres<br/>database oems)]
    INIT[db-init<br/>one-shot] -. creates databases + users .-> PG
  end
  CP[FIX counterparties] -- "FIX 9870-9899 (FIX_PORT_RANGE)" --> OEMS
  OEMS -- "initiators" --> CP
```

| Service | Image (built from) | Inside | Published by default | Purpose |
|---|---|---|---|---|
| `ui` | `sofix/ui-fe` (`sofix-ui-fe/Dockerfile`) | 8080 | `0.0.0.0:8080` | The app (nginx). Proxies `/api` and `/ws` to the backend, so the browser needs only this address |
| `backend` | `sofix/ui-be` (`sofix-ui-be/Dockerfile`) | 8090 | `127.0.0.1:8090` | Users, access, the app's data; forwards FIX work to the OEMS |
| `oems` | `sofix/oems` (`sofix-oems/Dockerfile`) | 8095, FIX ports | `127.0.0.1:8095`, `0.0.0.0:9870-9899` | FIX sessions, orders, certification |
| `postgres` | `postgres:17-alpine` | 5432 | `127.0.0.1:5433` | One server, two databases: `sofix` (backend) and `oems` |
| `db-init` | `postgres:17-alpine` | — | — | Runs at each `up`, then exits: creates the databases and users when missing, sets their passwords |

Start order: `postgres` (healthy) → `db-init` (done) → `oems` → `backend` (healthy) → `ui`.
The backend waits for the OEMS on its own and tells the app while it is unreachable.

## 2. Common setups

### 2.1 One machine (defaults)

Nothing to set. App on `http://localhost:8080`; backend `:8090`, OEMS `:8095` and PostgreSQL
`:5433` only on this machine.

### 2.2 A server reached by IP or name

```dotenv
PUBLIC_URL=http://10.20.30.40:8080        # what users type in the browser
INITIAL_ADMIN_PASSWORD=<a strong password>
POSTGRES_SUPERUSER_PASSWORD=<…>
UI_DB_PASSWORD=<…>
OEMS_DB_PASSWORD=<…>
OEMS_SECRET_KEY=<openssl rand -base64 32>
ALLOWED_ORIGIN=http://10.20.30.40:8080
```

Users open `http://10.20.30.40:8080`. Nothing else needs the server's address: the app calls
`/api` and `/ws` on the address it was loaded from. Open the UI port and the FIX port range in
the server's firewall; keep 8090, 8095 and 5433 closed (they are bound to 127.0.0.1).

Another UI port: `UI_HOST_PORT=80` and `PUBLIC_URL=http://10.20.30.40`.

### 2.3 Behind HTTPS (a reverse proxy or load balancer)

Terminate TLS in front of the `ui` port and forward to it (WebSocket upgrade on `/ws` must be
allowed). Set `PUBLIC_URL=https://sofix.example.com`; the app switches to `wss://` itself. Bind
the UI to the proxy only: `UI_BIND=127.0.0.1`.

### 2.4 Databases on another PostgreSQL server

```dotenv
UI_DB_HOST=db.example.com
UI_DB_PORT=5432
UI_DB_NAME=sofix
UI_DB_USER=sofix_app
UI_DB_PASSWORD=<…>
UI_DB_URL_PARAMS=?sslmode=require
OEMS_DB_HOST=db.example.com
OEMS_DB_NAME=oems
OEMS_DB_USER=oems_app
OEMS_DB_PASSWORD=<…>
OEMS_DB_URL_PARAMS=?sslmode=require
```

Either let `db-init` create the databases there (`DB_INIT_HOST=db.example.com`,
`POSTGRES_SUPERUSER` / `POSTGRES_SUPERUSER_PASSWORD` = an account allowed to create roles and
databases), or create them yourself (see `docker/postgres/init-databases.sh`) and start without
the local server: `docker compose up -d --no-deps oems backend ui`.
Passwords inside `DATABASE_URL` must be URL-safe (avoid `@ : / ? #`, or percent-encode them).

### 2.5 Developing one part outside Docker

| Working on | Run in Docker | Run on the host | Settings |
|---|---|---|---|
| The app (live reload) | `docker compose up -d postgres db-init oems backend` | `cd sofix-ui-fe && npm start` → `http://localhost:4200` | none: ng serve uses `localhost:8090` |
| The OEMS | `docker compose up -d postgres db-init backend ui` | `cd sofix-oems && OEMS_DB_URL=jdbc:postgresql://localhost:5433/oems java -jar oems-app/target/oems-app-0.1.0-SNAPSHOT.jar` | `OEMS_URL=http://host.docker.internal:8095` in `.env` |
| The backend | `docker compose up -d postgres db-init oems` | `cd sofix-ui-be && DATABASE_URL=postgres://sofix:sofix@localhost:5433/sofix OEMS_URL=http://localhost:8095 npm start` | `OEMS_BIND`: keep 127.0.0.1 (published) |

### 2.6 A buy-side stack next to the sell side, on the same machine

To run the buy side from terminals instead (only its database in Docker): `local-buy-side.md`.

Run a second project with its own mode, name, ports and volumes:

```bash
DEPLOYMENT_MODE=BUY_SIDE COMPOSE_PROJECT_NAME=sofix-buy UI_HOST_PORT=8180 BACKEND_HOST_PORT=8190 OEMS_HOST_PORT=8195 \
POSTGRES_HOST_PORT=5533 FIX_PORT_RANGE=9970-9999 POSTGRES_VOLUME=sofix-buy_postgres-data \
OEMS_FIX_DATA_VOLUME=sofix-buy_oems-fix-data OEMS_LOGS=./logs/oems-buy \
docker compose up -d
```

Its OEMS reaches the first one's acceptors at `host.docker.internal:<port>`.

## 3. Every setting

Defaults are what applies when the variable is not set. "Restart" = `docker compose up -d`
after changing it (compose recreates the containers whose settings changed).

### 3.1 Stack

| Variable | Default | Meaning |
|---|---|---|
| `DEPLOYMENT_MODE` | `SELL_SIDE` | Which side this stack serves: `SELL_SIDE` (a broker answering client orders) or `BUY_SIDE` (companies sending orders to brokers). Passed to the OEMS (`sofix.deployment.mode`) and the backend; the app shows that side's panels |
| `COMPOSE_PROJECT_NAME` | `sofix` | Name of the stack: containers are `sofix-<service>-1`, the network `sofix_default` |
| `RESTART_POLICY` | `unless-stopped` | `no`, `always`, `unless-stopped`, `on-failure` for ui, backend, oems, postgres |
| `DOCKER_LOG_MAX_SIZE` / `DOCKER_LOG_MAX_FILES` | `20m` / `5` | Rotation of each container's stdout log (`docker compose logs`) |
| `TZ` | `UTC` | Time zone of every container |
| `IMAGE_PREFIX` / `IMAGE_TAG` | `sofix` / `local` | Image names `sofix/oems:local`, `sofix/ui-be:local`, `sofix/ui-fe:local`; set a registry prefix and version to push them |

### 3.2 Access (the app)

| Variable | Default | Meaning |
|---|---|---|
| `PUBLIC_URL` | `http://localhost:8080` | The address users type. Used for sign-in redirects (SSO) |
| `UI_BIND` | `0.0.0.0` | Interface the app listens on: `0.0.0.0` all (other machines), `127.0.0.1` this machine only |
| `UI_HOST_PORT` | `8080` | Port of the app on the host |
| `UI_MAX_UPLOAD_SIZE` | `25m` | Largest upload (specification PDFs; the backend takes up to 20 MB) |
| `UI_PROXY_TIMEOUT` | `300s` | How long the app's proxy waits for the backend (the streamed spec conversion included) |
| `SOFIX_API_URL` | `/api` | Where the browser sends API calls. Relative = through the app's address. Absolute only when the backend is published elsewhere |
| `SOFIX_WS_URL` | `/ws` | Where the browser opens the event stream (`/ws` becomes `ws://` or `wss://` on the page's host) |
| `BACKEND_UPSTREAM` | `http://backend:8090` | Where the app's proxy finds the backend (another host: `http://10.20.30.41:8090`) |

### 3.3 Backend (sofix-ui-be)

| Variable | Default | Meaning |
|---|---|---|
| `BACKEND_BIND` / `BACKEND_HOST_PORT` | `127.0.0.1` / `8090` | Published backend port (for `npm start` in sofix-ui-fe and tools) |
| `OEMS_URL` | `http://oems:8095` | Where the backend finds the OEMS (`http://host.docker.internal:8095` for an OEMS on the host) |
| `ALLOWED_ORIGIN` | `*` | CORS origin for direct calls to the backend; set the app's address in production |
| `INITIAL_ADMIN_PASSWORD` | `sofix-admin` | Password of `operator`, set only while nobody has a password |
| `SESSION_HOURS` | `12` | How long a sign-in lasts |
| `ENABLE_TEST_API` | `0` | `1` enables `POST /api/test/reset` (e2e only) |
| `OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` | empty | SSO (OpenID Connect); offered only when all three are set |
| `OIDC_PROVIDER_NAME` | `SSO` | Shown on the button "Sign in with …" |
| `OIDC_REDIRECT_URI` | `${PUBLIC_URL}/api/auth/sso/callback` | Register it at the provider |
| `OIDC_SCOPES` | `openid email profile` | |

### 3.4 FIX OEMS (sofix-oems)

| Variable | Default | Meaning |
|---|---|---|
| `OEMS_BIND` / `OEMS_HOST_PORT` | `127.0.0.1` / `8095` | Published REST API and Actuator (`/actuator/health`, `/actuator/prometheus`) |
| `FIX_BIND` | `0.0.0.0` | Interface the FIX acceptor ports listen on |
| `FIX_PORT_RANGE` | `9870-9899` | Published FIX ports, same numbers inside and outside. **An acceptor session must use a port in this range** |
| `OEMS_SECRET_KEY` | empty (built-in development key, warning logged) | Base64 AES-256 key for stored SSL passwords (`openssl rand -base64 32`). Set once: changing it makes stored SSL passwords unreadable |
| `OEMS_JAVA_OPTS` | `-XX:MaxRAMPercentage=75` | JVM options, e.g. `-Xmx2g` |
| `OEMS_LOGS` | `./logs/oems` | Host folder for the OEMS log files (`oems-app.log`, `oems-error.log`, `oems-audit.log`, `oems-perf.log`, `fix-session-<id>.log`) |
| `OEMS_FIX_DATA_VOLUME` | `sofix_oems-fix-data` | Volume of the QuickFIX/J stores (sequence numbers, uploaded dictionaries) |
| `OEMS_CERTIFICATION_CHUNK_DELAY` | `900ms` | Pace of the simulated specification conversion (`0ms` = instant) |
| `OEMS_CERTIFICATION_TEST_CASES_DELAY` | `1500ms` | Delay before generated test cases are returned |
| `OEMS_SPECIFICATION_CATALOG` | `classpath` | Where specifications come from (`sofix.extensions.specification-catalog`) |
| `OEMS_FIX_DICTIONARY` | `qfj` | How Message Details describes messages: `qfj` (session dictionary) or `plain` |

### 3.5 PostgreSQL and the two databases

| Variable | Default | Meaning |
|---|---|---|
| `POSTGRES_VERSION` | `17` | PostgreSQL image version (server and db-init) |
| `POSTGRES_SUPERUSER` / `POSTGRES_SUPERUSER_PASSWORD` | `sofix` / `sofix` | The server's administrator; db-init uses it. Applies when the volume is first created; changing it later does not rename the existing administrator |
| `POSTGRES_BIND` / `POSTGRES_HOST_PORT` | `127.0.0.1` / `5433` | Published port for database tools and host-run services |
| `POSTGRES_VOLUME` | `sofix-mock-backend_postgres-data` | Volume with the data; the default keeps the earlier setup's data |
| `UI_DB_NAME` / `UI_DB_USER` / `UI_DB_PASSWORD` | `sofix` / `sofix` / `sofix` | The backend's database |
| `UI_DB_HOST` / `UI_DB_PORT` | `postgres` / `5432` | Its server (another one: see 2.4) |
| `UI_DB_URL_PARAMS` | empty | Appended to the backend's database URL, e.g. `?sslmode=require` |
| `OEMS_DB_NAME` / `OEMS_DB_USER` / `OEMS_DB_PASSWORD` | `oems` / `oems` / `oems` | The OEMS's database |
| `OEMS_DB_HOST` / `OEMS_DB_PORT` | `postgres` / `5432` | Its server |
| `OEMS_DB_URL_PARAMS` | empty | Appended to the OEMS's JDBC URL, e.g. `?sslmode=require` |
| `DB_INIT_HOST` / `DB_INIT_PORT` | `postgres` / `5432` | Where db-init creates databases and users |

db-init never drops anything. It creates a missing user or database, and sets each user's
password from the environment at every start (so changing `UI_DB_PASSWORD` and running
`docker compose up -d` changes it in the database too).

## 4. Data, logs and backups

| What | Where | Kept when |
|---|---|---|
| Both databases | volume `POSTGRES_VOLUME` | `docker compose down` (not with `down -v`) |
| QuickFIX/J stores | volume `OEMS_FIX_DATA_VOLUME` | same |
| OEMS log files | host folder `OEMS_LOGS` | always (files on the host) |
| Container stdout | Docker (`docker compose logs -f <service>`) | until the container is removed; rotated |

Backup and restore:

```bash
docker compose exec -T postgres pg_dump -U sofix -d sofix  > sofix-$(date +%F).sql
docker compose exec -T postgres pg_dump -U oems  -d oems   > oems-$(date +%F).sql
docker compose exec -T postgres psql -U oems -d oems < oems-2026-10-12.sql   # restore
```

## 5. Everyday commands

```bash
docker compose up -d --build            # build changed images and (re)start what changed
docker compose ps                       # state and health
docker compose logs -f backend oems     # follow logs
docker compose restart backend          # restart one service
docker compose up -d --build oems       # rebuild and restart only the OEMS after a code change
docker compose down                     # stop and remove containers (data stays)
docker compose exec backend node src/set-password.js operator   # locked out
```

## 6. Moving from the earlier setup (once)

Before 2026-10-12 the OEMS ran on the host and had its own PostgreSQL container
(`oems-postgres`, port 5434, volume `fix-oems_oems-pgdata`); the Mock Engine ran in `engine`.

1. Stop the OEMS you run on the host (it would hold port 8095).
2. `docker compose up -d --build --remove-orphans` (removes the old `engine` and
   `oems-postgres` containers; their volumes stay).
3. Copy the OEMS data (sessions, settings, preferences) into the single server:
   `./scripts/copy-old-oems-data.sh`. It reads the old volume, replaces the new `oems`
   database's content and restarts the OEMS.
4. When everything is there: `docker volume rm fix-oems_oems-pgdata`.

The app's database (users, layouts, templates…) is already on the single server: the default
`POSTGRES_VOLUME` is the volume it used before.

## 7. FIX sessions in Docker

* **Acceptors** listen inside the `oems` container on the port the session names; only ports in
  `FIX_PORT_RANGE` are reachable from outside. Counterparties connect to the server's IP and
  that port.
* **Initiators** connect out from the container. `localhost` there is the container itself:
  use `host.docker.internal` for a counterparty on the Docker host, a service name for another
  container, or the counterparty's IP or name.
* Sequence numbers live in `OEMS_FIX_DATA_VOLUME`, so they survive container rebuilds.

## 8. Known limitations

1. The backend talks to the OEMS over plain HTTP inside the Docker network, with the user in a
   header; the signed token of the design is not built yet (see
   `docs/features/order-visibility.md`).
2. One instance of each service: no clustering or failover.
3. HTTPS is left to a reverse proxy in front (2.3).
4. `FIX_PORT_RANGE` must be decided up front: an acceptor on a port outside it is unreachable.
5. Buy-Side Simulator test runs are paused (the Mock Engine that ran them is retired).
