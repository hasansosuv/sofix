# Loading the latest changes: commands, restarts, checks

How to get new code running in all three repositories, for the two setups in use on this machine:

- **Sell side**: the Docker stack (compose project `sofix`): app, backend, OEMS, PostgreSQL.
- **Buy side**: the OEMS, backend and app run from three terminals; only its PostgreSQL runs in
  Docker (compose project `sofix-buy`).

Setting the two up for the first time: `docker.md` (sell side) and `local-buy-side.md` (buy side).
This page is for the day-to-day: after code has changed, how to make it take effect.

All commands start in the workspace folder `~/Downloads/SOSUV/sofix` unless they `cd` elsewhere.

## 1. At a glance

| | Sell side (Docker) | Buy side (terminals) |
|---|---|---|
| App | http://localhost:8080 (container `ui`) | http://localhost:4300 (`npm run start:buy-side`) |
| Backend | :8090 (container `backend`) | :8190 (`npm start`) |
| OEMS | :8095 (container `oems`), FIX acceptors 9870–9899 | :8195 (`java -jar ~/oems-buy.jar`) |
| PostgreSQL | :5433 (container `postgres`, project `sofix`) | :5533 (container `postgres`, project `sofix-buy`) |
| Make a change take effect | `docker compose up -d --build` | rebuild what changed, `Ctrl+C`, start again (section 4) |

| What changed | Sell side | Buy side |
|---|---|---|
| `sofix-oems` (Java) | `docker compose up -d --build oems` | `./mvnw -q -DskipTests package`, copy the jar, restart the OEMS terminal |
| `sofix-ui-be` (Node) | `docker compose up -d --build backend` | restart the backend terminal (`npm install` first if `package.json` changed) |
| `sofix-ui-fe` (Angular) | `docker compose up -d --build ui` | nothing: `ng serve` reloads by itself; restart it only if `package.json`, `angular.json` or `src/environments/` changed |
| All three | `docker compose up -d --build` | all of the above |
| `compose.yaml` or `.env` | `docker compose up -d` (adds `--build` if code changed too) | `docker/buy-side-db.env`: `docker compose --env-file docker/buy-side-db.env up -d postgres db-init` |
| Database schema (new Flyway migration in the OEMS) | nothing extra: the OEMS applies it when it starts | nothing extra: same |

## 2. Get the latest code (both sides)

Each repository has its own history; pull each one you need. Everything is on `main`.

```bash
cd ~/Downloads/SOSUV/sofix
git pull                       # the workspace: compose.yaml, .env.example, docs
git -C sofix-oems  pull        # the OEMS
git -C sofix-ui-be pull        # the backend
git -C sofix-ui-fe pull        # the app
```

To see what you have (each repository's last commit):

```bash
for r in . sofix-oems sofix-ui-be sofix-ui-fe; do echo "$r: $(git -C $r log --oneline -1)"; done
```

If a pull reports local changes in the way, look at them with `git -C <repo> status` before doing
anything else; do not discard changes you did not make.

## 3. Sell side (Docker)

### 3.1 Rebuild and restart

```bash
cd ~/Downloads/SOSUV/sofix
docker compose up -d --build
```

What this does:

Orders are kept in memory by the OEMS for now: rebuilding or restarting the `oems` container
loses the sell side's orders (sessions, settings and users stay).

1. Builds a new image for each service whose code changed (`sofix/oems:local`,
   `sofix/ui-be:local`, `sofix/ui-fe:local`). The OEMS image runs the Maven build inside Docker,
   the app image runs `ng build`; the first build takes a few minutes, later ones use the cache.
2. Replaces only the containers whose image or settings changed; the others keep running.
3. Keeps the data: the databases live in the volume `sofix-mock-backend_postgres-data` and the
   FIX stores (sequence numbers) in `sofix_oems-fix-data`. Neither is touched by a rebuild.
4. Runs `db-init` (creates databases and users if missing) before the OEMS and the backend
   start; the OEMS then applies new Flyway migrations to the `oems` database itself.

One service only (faster when you know what changed):

```bash
docker compose up -d --build oems       # sofix-oems changed
docker compose up -d --build backend    # sofix-ui-be changed
docker compose up -d --build ui         # sofix-ui-fe changed
```

### 3.2 Restart without rebuilding

```bash
docker compose restart oems             # same image, fresh start (e.g. after a hang)
docker compose restart backend
docker compose up -d                    # after editing .env or compose.yaml
```

`restart` does not pick up code changes or `.env` changes; use `up -d --build` for code and
`up -d` for settings.

### 3.3 Check it is running the new code

```bash
docker compose ps                                  # every service "running", backend/ui "healthy"
docker compose logs -f oems                        # wait for "Started OemsApplication"
docker compose logs -f backend                     # "listening on :8090", "database ready"
curl -s localhost:8095/actuator/health             # {"status":"UP"}
curl -s localhost:8090/api/health
```

Then reload the app in the browser at http://localhost:8080. The browser may keep the old app
in its cache: use a hard reload (`Cmd+Shift+R`). A new browser-tab icon in particular is cached
hard; if it stays old, close the tab and open the address again.

### 3.4 Logs

| What | Where |
|---|---|
| Container output | `docker compose logs -f <oems/backend/ui/postgres>` (`--since 10m` to limit) |
| OEMS log files (app, errors, audit, per FIX session) | `./logs/oems/` in the workspace folder |

### 3.5 Stop and start again

```bash
docker compose stop          # stop everything; data stays
docker compose start         # start the same containers again
docker compose down          # stop and remove the containers; data stays
docker compose up -d         # create and start them again
```

Never use `docker compose down -v` on the sell side unless you mean to delete both databases
and the FIX stores.

## 4. Buy side (three terminals)

The buy side's OEMS, backend and app run from terminals so you can read their logs as they run.
A running program keeps the code it started with: to load a change, stop it (`Ctrl+C` in its
terminal) and start it again. Order matters only at start-up: database → OEMS → backend → app.

### 4.1 The database (Docker, once)

It keeps running across restarts of the other three; start it only after a reboot or a
`docker compose ... stop`:

```bash
cd ~/Downloads/SOSUV/sofix
docker compose --env-file docker/buy-side-db.env up -d postgres db-init
docker compose --env-file docker/buy-side-db.env ps        # postgres "healthy"
```

### 4.2 Terminal 1: the OEMS (port 8195)

After a change in `sofix-oems`, build the jar, copy it, and restart:

```bash
# 1. stop the running OEMS: Ctrl+C in its terminal

# 2. build (skips the tests; about a minute)
cd ~/Downloads/SOSUV/sofix/sofix-oems
./mvnw -q -DskipTests package

# 3. copy the jar: the buy side runs a copy, so a later build (or ./mvnw verify) does not
#    replace the file under the running OEMS
cp oems-app/target/oems-app-0.1.0-SNAPSHOT.jar ~/oems-buy.jar

# 4. start it again
SOFIX_DEPLOYMENT_MODE=BUY_SIDE OEMS_HTTP_PORT=8195 \
OEMS_DB_URL=jdbc:postgresql://localhost:5533/oems \
OEMS_FIX_DATA_DIR=data/qfj-buy OEMS_LOG_DIR=logs/buy \
java -jar ~/oems-buy.jar
```

Ready when the log shows `Started OemsApplication`; check with
`curl -s localhost:8195/actuator/health`. New database tables (Flyway migrations) are created at
this start. FIX sessions that were started before come back on their own and log on again.

Orders are kept in memory for now (on both sides): a restart of the buy-side OEMS loses its orders (sessions,
templates, suites and users stay, they are in the database).

### 4.3 Terminal 2: the backend (port 8190)

```bash
# 1. stop it: Ctrl+C in its terminal

# 2. only when sofix-ui-be/package.json changed
cd ~/Downloads/SOSUV/sofix/sofix-ui-be
npm install

# 3. start it again
DEPLOYMENT_MODE=BUY_SIDE PORT=8190 OEMS_URL=http://localhost:8195 \
DATABASE_URL=postgres://sofix:sofix@localhost:5533/sofix \
npm start
```

Ready when it prints `listening` and `database ready`; check with
`curl -s localhost:8190/api/health`. If the OEMS is not up yet, the backend waits for it and
tells the app (the top bar shows the OEMS as down until it connects).

### 4.4 Terminal 3: the app (port 4300)

`ng serve` watches the source: after a change in `sofix-ui-fe` it rebuilds and the browser
reloads by itself (watch the terminal for "Compiled successfully" or errors). Restart it only
when `package.json`, `angular.json`, `src/environments/` or `public/` changed, or when it stops
reloading:

```bash
# 1. stop it: Ctrl+C in its terminal

# 2. only when sofix-ui-fe/package.json changed
cd ~/Downloads/SOSUV/sofix/sofix-ui-fe
npm install

# 3. start it again
npm run start:buy-side
```

Open http://localhost:4300 (hard reload, `Cmd+Shift+R`, if the page looks old).

### 4.5 Everything at once (after pulling all three)

1. `Ctrl+C` in the app, backend and OEMS terminals.
2. Database: running? If not, section 4.1.
3. Terminal 1: build, copy and start the OEMS (4.2); wait for `Started OemsApplication`.
4. Terminal 2: start the backend (4.3).
5. Terminal 3: start the app (4.4).
6. Open http://localhost:4300; sign in.
7. Sessions: start the FIX session to the sell side if it is not logged on.

## 5. Both sides after a change to all three repositories

```bash
cd ~/Downloads/SOSUV/sofix
git pull && git -C sofix-oems pull && git -C sofix-ui-be pull && git -C sofix-ui-fe pull

# sell side
docker compose up -d --build

# buy side: OEMS jar (Docker's build above does not touch it)
cd sofix-oems && ./mvnw -q -DskipTests package && cp oems-app/target/oems-app-0.1.0-SNAPSHOT.jar ~/oems-buy.jar
# then restart the buy side's OEMS, backend and app terminals (section 4.5)
```

The FIX session between the two sides drops while either OEMS restarts; the buy side's initiator
reconnects by itself (every `reconnectIntervalSec`), so start order between the sides does not
matter.

## 6. When something goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `EADDRINUSE: address already in use :::8190` (or `Port 8195 was already in use`, or ng serve asks for another port) | The previous instance is still running (another terminal, or left over) | Find it: `lsof -nP -iTCP:8190 -sTCP:LISTEN`; stop it with `Ctrl+C` in its terminal or `kill <PID>`, then start again |
| Sell side still shows old behaviour | Started with `restart` (no rebuild), or the browser cached the old app | `docker compose up -d --build <service>`; hard reload the browser |
| Buy side OEMS still shows old behaviour | Started the old `~/oems-buy.jar` | Build and **copy** the jar again (4.2), then restart |
| Build fails: `docker compose up -d --build` | A compile error in one repository | Read the build output (`docker compose build oems` shows it alone); the running containers keep the previous version |
| OEMS stops at start-up with a Flyway or database error | The database is not running, or another OEMS version changed the schema | Check the database (`docker compose ps`, or with `--env-file docker/buy-side-db.env`); read `logs/oems/oems-error.log` (sell side) or `sofix-oems/logs/buy/oems-error.log` (buy side) |
| Backend: "OEMS unreachable" / top bar shows the OEMS down | The OEMS is still starting, or stopped | Wait for `Started OemsApplication`; check the OEMS terminal or `docker compose logs oems` |
| The order ticket lists no Target Session | The buy-side session's role is not BUY_SIDE | Sessions → stop it → Edit → Role BUY_SIDE → save → start |
| FIX session stays "Attempting" | The other side's acceptor is not running, or wrong host/port/CompIDs | Sell side acceptor on a port in 9870–9899 and started; buy side initiator `localhost`, same port, CompIDs mirrored |
| Signed out / password not accepted after a reset of the database | A fresh database has only `operator` with `INITIAL_ADMIN_PASSWORD` | Sign in as `operator` / `sofix-admin`; locked out: `docker compose exec backend node src/set-password.js operator` (sell side) or `cd sofix-ui-be && DATABASE_URL=postgres://sofix:sofix@localhost:5533/sofix node src/set-password.js operator` (buy side) |

## 7. What is not lost on a restart

| Kept | Lost |
|---|---|
| Users, roles, rights, layouts (backend database) | Orders on both sides and their messages: the OEMS keeps them in memory for now (`docs/features/order-lifecycle.md`, limitation 1) |
| FIX sessions and their settings, session templates, test suites, preferences (OEMS database) | |
| FIX sequence numbers (FIX store: volume on the sell side, `sofix-oems/data/qfj-buy` on the buy side) | Open browser state that was not saved as a layout |
