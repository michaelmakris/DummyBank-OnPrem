#!/bin/sh
# Read-only logins: the customer API (all of core) and the credit engine (the exposure table
# only, like a DBA would grant on a data warehouse). Passwords from the mounted secret files.
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v api_password="$(cat /run/secrets/core-api-password)" \
  -v engine_password="$(cat /run/secrets/dwh-password)" <<'SQL'
CREATE ROLE customer_api LOGIN PASSWORD :'api_password';
GRANT USAGE ON SCHEMA core TO customer_api;
GRANT SELECT ON ALL TABLES IN SCHEMA core TO customer_api;

CREATE ROLE ccp_reader LOGIN PASSWORD :'engine_password';
GRANT USAGE ON SCHEMA risk TO ccp_reader;
GRANT SELECT ON risk.customer_exposure_daily TO ccp_reader;
SQL
