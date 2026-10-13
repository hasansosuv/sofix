# Running the buy side from terminals, next to the sell side in Docker

The **sell side** runs as the Docker stack (`docker compose up -d`, see `docker.md`). The **buy
side** runs its OEMS, backend and app from terminals, and only its database in Docker, as a
separate compose project (`sofix-buy`). Nothing is shared between the two except the FIX
session that connects them.

| | Sell side (Docker, project `sofix`) | Buy side (terminals + project `sofix-buy`) |
|---|---|---|
| App | http://localhost:8080 (or `npm start` → 4200) | `npm run start:buy-side` → **http://localhost:4300** |
| Backend | 8090 | **8190** |
| OEMS | 8095 | **8195** |
| PostgreSQL | 5433 (volume `sofix-mock-backend_postgres-data`) | **5533** (volume `sofix-buy_postgres-data`) |
| FIX acceptors | 9870–9899 (published) | any other port |
| `DEPLOYMENT_MODE` | SELL_SIDE | BUY_SIDE |

## Start (four terminals, workspace folder `sofix/`)

```bash
# 1. the buy side's database (once; it keeps running)
docker compose --env-file docker/buy-side-db.env up -d postgres db-init

# 2. OEMS on 8195 (run from a copy of the jar: ./mvnw verify rewrites the one in target/)
cd sofix-oems
cp oems-app/target/oems-app-0.1.0-SNAPSHOT.jar ~/oems-buy.jar
SOFIX_DEPLOYMENT_MODE=BUY_SIDE OEMS_HTTP_PORT=8195 \
OEMS_DB_URL=jdbc:postgresql://localhost:5533/oems \
OEMS_FIX_DATA_DIR=data/qfj-buy OEMS_LOG_DIR=logs/buy \
java -jar ~/oems-buy.jar

# 3. backend on 8190
cd sofix-ui-be
DEPLOYMENT_MODE=BUY_SIDE PORT=8190 OEMS_URL=http://localhost:8195 \
DATABASE_URL=postgres://sofix:sofix@localhost:5533/sofix \
npm start

# 4. app on 4300
cd sofix-ui-fe
npm run start:buy-side
```

Open http://localhost:4300 and sign in as `operator` / `sofix-admin` (a fresh database; change it
in Users). Then add companies (Administration → Companies) and their users.

`OEMS_FIX_DATA_DIR` and `OEMS_LOG_DIR` keep the buy side's QuickFIX/J stores and log files apart
from a sell-side OEMS run from the same folder.

## Connecting the two sides over FIX

On the **sell side** (Docker) an ACCEPTOR session, role SELL_SIDE, port in 9870–9899 (e.g. 9889).
On the **buy side** an INITIATOR session, role BUY_SIDE, host `localhost`, the same port, the
CompIDs mirrored (buy side sender = sell side target). Start both: they log on.

## Stop

Loading new code after a change (both sides, step by step): `updating-and-restarting.md`.

`Ctrl+C` in terminals 2–4; the database: `docker compose --env-file docker/buy-side-db.env stop`.
Remove it with its data: `docker compose --env-file docker/buy-side-db.env down -v` (only the
`sofix-buy` project's volume).
