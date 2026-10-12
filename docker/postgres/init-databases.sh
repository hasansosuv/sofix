#!/bin/sh
# Creates (or updates) the two databases and their users on the PostgreSQL server, as the
# compose `db-init` job. Idempotent: run at every `docker compose up`, it creates what is
# missing and sets the passwords from the environment, never dropping anything.
#   UI_DB_NAME / UI_DB_USER / UI_DB_PASSWORD        the backend's database (sofix-ui-be)
#   OEMS_DB_NAME / OEMS_DB_USER / OEMS_DB_PASSWORD  the OEMS's database (sofix-oems)
# Connection: PGHOST, PGPORT, PGUSER, PGPASSWORD (a superuser).
set -eu

psql -v ON_ERROR_STOP=1 -d postgres \
  -v ui_db="$UI_DB_NAME" -v ui_user="$UI_DB_USER" -v ui_pw="$UI_DB_PASSWORD" \
  -v oems_db="$OEMS_DB_NAME" -v oems_user="$OEMS_DB_USER" -v oems_pw="$OEMS_DB_PASSWORD" <<'SQL'
-- Users: created when missing; the password always follows the environment.
SELECT format('CREATE ROLE %I LOGIN', :'ui_user')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'ui_user') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'ui_user', :'ui_pw') \gexec
SELECT format('CREATE ROLE %I LOGIN', :'oems_user')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'oems_user') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'oems_user', :'oems_pw') \gexec

-- Databases: created when missing, owned by their user.
SELECT format('CREATE DATABASE %I OWNER %I', :'ui_db', :'ui_user')
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'ui_db') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'oems_db', :'oems_user')
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'oems_db') \gexec

-- Each user may use its own database (also when it existed before with another owner).
SELECT format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', :'ui_db', :'ui_user') \gexec
SELECT format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', :'oems_db', :'oems_user') \gexec
SQL

# PostgreSQL 15+: the public schema needs CREATE for the owner's user explicitly.
psql -v ON_ERROR_STOP=1 -d "$UI_DB_NAME" -c "GRANT ALL ON SCHEMA public TO \"$UI_DB_USER\"" >/dev/null
psql -v ON_ERROR_STOP=1 -d "$OEMS_DB_NAME" -c "GRANT ALL ON SCHEMA public TO \"$OEMS_DB_USER\"" >/dev/null
echo "databases ready: $UI_DB_NAME ($UI_DB_USER), $OEMS_DB_NAME ($OEMS_DB_USER)"
