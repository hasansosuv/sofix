#!/bin/sh
# One-time copy of the OEMS data (FIX sessions, business settings, users, preferences…) from the
# separate PostgreSQL the OEMS used before (volume fix-oems_oems-pgdata, port 5434) into the
# oems database of the single PostgreSQL server in compose.yaml.
#
#   ./scripts/copy-old-oems-data.sh            run in this folder, after `docker compose up -d postgres db-init`
#
# The old volume is only read (a temporary container opens it) and is kept; delete it yourself
# once satisfied: docker volume rm fix-oems_oems-pgdata. The OEMS container is stopped during
# the copy and started again. What is in the new oems database is replaced.
# Settings (same as compose): OEMS_DB_NAME, OEMS_DB_USER (default oems); OLD_OEMS_VOLUME,
# OLD_OEMS_DB_NAME, OLD_OEMS_DB_USER (default fix-oems_oems-pgdata, oems, oems).
set -eu
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

OLD_VOLUME="${OLD_OEMS_VOLUME:-fix-oems_oems-pgdata}"
OLD_DB="${OLD_OEMS_DB_NAME:-oems}"
OLD_USER="${OLD_OEMS_DB_USER:-oems}"
NEW_DB="${OEMS_DB_NAME:-oems}"
NEW_USER="${OEMS_DB_USER:-oems}"
TEMP="sofix-old-oems-db-$$"

docker volume inspect "$OLD_VOLUME" >/dev/null 2>&1 || { echo "No volume $OLD_VOLUME: nothing to copy."; exit 0; }

# A container still running on the old volume (the earlier oems-postgres) is used as it is;
# otherwise a temporary one opens the volume.
OLD_CONTAINER="$(docker ps -q --filter "volume=$OLD_VOLUME" | head -n 1)"
if [ -z "$OLD_CONTAINER" ]; then
  echo "Opening $OLD_VOLUME in a temporary container…"
  docker run -d --rm --name "$TEMP" -e POSTGRES_PASSWORD=unused \
    -v "$OLD_VOLUME":/var/lib/postgresql/data "postgres:${POSTGRES_VERSION:-17}-alpine" >/dev/null
  OLD_CONTAINER="$TEMP"
  trap 'docker stop "$TEMP" >/dev/null 2>&1 || true' EXIT
  until docker exec "$TEMP" pg_isready -U "$OLD_USER" -d "$OLD_DB" >/dev/null 2>&1; do sleep 1; done
fi

echo "Stopping the OEMS during the copy…"
docker compose stop oems >/dev/null 2>&1 || true

echo "Copying $OLD_DB (old) → $NEW_DB (single server)…"
docker exec "$OLD_CONTAINER" pg_dump -U "$OLD_USER" -d "$OLD_DB" --clean --if-exists --no-owner --no-privileges \
  | docker compose exec -T postgres psql -q -v ON_ERROR_STOP=1 -U "$NEW_USER" -d "$NEW_DB" >/dev/null

echo "Rows copied:"
docker compose exec -T postgres psql -U "$NEW_USER" -d "$NEW_DB" -Atc \
  "select 'fix_session '||count(*) from fix_session union all select 'flyway versions '||count(*) from flyway_schema_history"

echo "Starting the OEMS…"
docker compose up -d oems >/dev/null
echo "Done. The old volume $OLD_VOLUME is untouched."
