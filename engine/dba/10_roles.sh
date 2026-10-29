#!/bin/sh
# DBA, once, on the engine's database: the first part of the vendor's grants.sql (roles and
# schema) plus passwords. The second part runs after the first migration (dba-grants service).
set -eu
sed -n '1,/Run AFTER the first migration/p' /vendor/grants.sql \
  | psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v app="$(cat /run/secrets/db-password)" -v mig="$(cat /run/secrets/db-migrator-password)" <<'SQL'
ALTER ROLE ccp_app PASSWORD :'app';
ALTER ROLE ccp_migrator PASSWORD :'mig';
SQL
