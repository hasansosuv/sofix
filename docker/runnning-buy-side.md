There is no separate compose file for the buy side. Both sides use the same compose.yaml. The buy side runs it as a second, separate Docker Compose project, with a small settings file, docker/buy-side-db.env:


COMPOSE_PROJECT_NAME=sofix-buy
POSTGRES_HOST_PORT=5533
POSTGRES_VOLUME=sofix-buy_postgres-data
OEMS_FIX_DATA_VOLUME=sofix-buy_oems-fix-data
DEPLOYMENT_MODE=BUY_SIDE
It's started with:


docker compose --env-file docker/buy-side-db.env up -d postgres db-init
That command starts only two services from compose.yaml:

postgres: a PostgreSQL server.
db-init: a one-shot job that creates the sofix (backend) and oems databases and their users, then exits.
The oems, backend and ui services aren't started for the buy side; you run those from the terminals.

The project name and volume in that env file keep everything apart from the sell side. This is running right now:

Sell side	Buy side
Compose project	sofix	sofix-buy
Container	sofix-postgres-1	sofix-buy-postgres-1
Port on your Mac	127.0.0.1:5433	127.0.0.1:5533
Data volume	sofix-mock-backend_postgres-data	sofix-buy_postgres-data
Databases inside	sofix (backend), oems	sofix (backend), oems
So the buy side has its own PostgreSQL server and its own data. Your buy-side terminals reach it on port 5533: the OEMS through jdbc:postgresql://localhost:5533/oems, the backend through postgres://sofix:sofix@localhost:5533/sofix.

Useful commands for the buy-side database (all from the workspace folder, always with the --env-file):


docker compose --env-file docker/buy-side-db.env ps          # is it running
docker compose --env-file docker/buy-side-db.env logs -f postgres
docker compose --env-file docker/buy-side-db.env stop        # stop (data kept)
docker compose --env-file docker/buy-side-db.env up -d postgres db-init   # start again
Without --env-file docker/buy-side-db.env, these commands act on the sell-side stack instead, because compose.yaml defaults to the sofix project. Never run down -v without that flag, or you'd delete the sell side's data.

This setup is also described in docs/deployment/local-buy-side.md and docs/deployment/docker.md §2.6.