#!/usr/bin/env bash
# Preparation of the dummy bank: random secrets, a private certificate authority with server
# certificates for every service, and the configuration generated from the effective ports
# (.env, the engine profile, the Keycloak realm). Secrets land in ./secrets, generated
# configuration in ./generated (both git-ignored).
#
#   bash scripts/setup.sh            # first time: everything; later: keeps the secrets and
#                                    # regenerates the configuration (e.g. after a port change)
#   bash scripts/setup.sh --force    # new secrets - only before the first start, or after
#                                    # deleting all data (docker compose down -v)
#
# Ports: ENGINE_PORT (console, default 28080) and SSO_PORT (Keycloak, default 18443), from the
# environment, else .env, else the default. They are written to .env so Docker Compose uses
# the same values.
#
# Needs: bash, openssl, docker. Written for Git Bash on Windows, works the same on Linux/macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1   # Git Bash: keep "/CN=..." as is

S=secrets
G=generated
fail() { echo "setup: $*" >&2; exit 1; }

# -- effective ports: environment > .env > default; written back to .env ----------------------
env_value() { grep -s "^$1=" .env | tail -n 1 | cut -d= -f2- || true; }
ENGINE_PORT=${ENGINE_PORT:-$(env_value ENGINE_PORT)}; ENGINE_PORT=${ENGINE_PORT:-28080}
SSO_PORT=${SSO_PORT:-$(env_value SSO_PORT)};          SSO_PORT=${SSO_PORT:-18443}
for port in "$ENGINE_PORT" "$SSO_PORT"; do
  [[ $port =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )) || fail "invalid port '$port'"
done
set_env() {  # set_env NAME VALUE: replace or add the line in .env
  touch .env
  grep -v "^$1=" .env > .env.new || true
  echo "$1=$2" >> .env.new && mv .env.new .env
}
set_env ENGINE_PORT "$ENGINE_PORT"
set_env SSO_PORT "$SSO_PORT"

# -- data of an installation: new secrets would lock it out -----------------------------------
PROJECT=${COMPOSE_PROJECT_NAME:-$(env_value COMPOSE_PROJECT_NAME)}
PROJECT=${PROJECT:-$(basename "$PWD" | tr '[:upper:]' '[:lower:]')}
installed_data() {  # the project's volumes: databases (passwords, decisions) and Keycloak
  docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" \
    || fail "cannot ask Docker for the installation's volumes (is Docker running?)"
}

REQUIRED=(core-db-admin-password core-api-password dwh-password engine-db-admin-password
          db-password db-migrator-password customer-api-client-secret model-api-token
          los-client-secret keycloak-admin-password customer-token-key
          password-admin password-admin2 password-editor password-approver password-viewer
          ca/ca.key tls/ca.pem
          tls/sso.pem tls/sso.key tls/customer-data.pem tls/customer-data.key
          tls/models.pem tls/models.key tls/core-db.pem tls/core-db.key
          tls/engine-db.pem tls/engine-db.key
          engine/ca.pem engine/db-password engine/dwh-password
          engine/customer-api-client-secret engine/customer-token-key engine/model-api-token
          engine-migration/ca.pem engine-migration/db-password
          engine-migration/db-migrator-password engine-migration/dwh-password
          engine-migration/customer-api-client-secret engine-migration/customer-token-key
          engine-migration/model-api-token)
missing() { for f in "${REQUIRED[@]}"; do [[ -s $S/$f ]] || echo "$f"; done; }

if [[ ${1:-} == --force ]]; then
  data=$(installed_data)
  [[ -z $data ]] || fail "refusing --force: the installation's data still exists
($(echo $data)). New secrets would no longer match the database passwords and Keycloak, and a
new customer-token key would cut the link between customers and their earlier decisions.
To start over and DELETE all data: docker compose down -v, then bash scripts/setup.sh --force"
  rm -rf "$S"
elif [[ -d $S ]]; then
  gaps=$(missing)
  if [[ -n $gaps ]]; then
    data=$(installed_data)
    hint="before the first start: bash scripts/setup.sh --force"
    [[ -z $data ]] || hint="restore them from the backup of secrets/ (the installation's data uses them)"
    fail "secrets/ is incomplete; missing: $(echo $gaps). $hint"
  fi
  echo "secrets/ complete: keeping them"
fi

# -- secrets and certificates (only when there are none yet) ----------------------------------
if [[ ! -d $S ]]; then
  mkdir -p "$S/ca" "$S/tls" "$S/engine" "$S/engine-migration"
  rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }

  # one file per secret, as a vault would mount them
  for name in core-db-admin-password core-api-password dwh-password engine-db-admin-password \
              db-password db-migrator-password customer-api-client-secret model-api-token \
              los-client-secret keycloak-admin-password; do
    rand 32 > "$S/$name"
  done
  rand 48 > "$S/customer-token-key"
  for user in admin admin2 editor approver viewer; do rand 16 > "$S/password-$user"; done

  # The credit engine's secret directories hold only what each part needs (least privilege):
  # engine/ for the API and the worker, engine-migration/ (adds the migration password) for
  # the one-off schema migration only.
  for name in db-password dwh-password customer-api-client-secret customer-token-key \
              model-api-token; do
    cp "$S/$name" "$S/engine/$name"
    cp "$S/$name" "$S/engine-migration/$name"
  done
  cp "$S/db-migrator-password" "$S/engine-migration/db-migrator-password"

  # private certificate authority + one certificate per service; the CA signing key stays in
  # secrets/ca, which no container mounts
  openssl req -x509 -newkey rsa:3072 -nodes -days 825 -subj "/CN=Dummy Bank Internal CA" \
    -keyout "$S/ca/ca.key" -out "$S/tls/ca.pem" 2>/dev/null
  cert() {  # cert <file name> <subject alt names>
    openssl req -newkey rsa:2048 -nodes -subj "/CN=$1" -keyout "$S/tls/$1.key" \
      -out "$S/tls/$1.csr" 2>/dev/null
    printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$2" > "$S/tls/$1.ext"
    openssl x509 -req -in "$S/tls/$1.csr" -CA "$S/tls/ca.pem" -CAkey "$S/ca/ca.key" \
      -CAserial "$S/ca/ca.srl" -CAcreateserial -days 825 -extfile "$S/tls/$1.ext" \
      -out "$S/tls/$1.pem" 2>/dev/null
    rm "$S/tls/$1.csr" "$S/tls/$1.ext"
  }
  cert sso           "DNS:sso.dummybank.internal,DNS:localhost,IP:127.0.0.1"
  cert customer-data "DNS:customer-data.dummybank.internal"
  cert models        "DNS:models.dummybank.internal"
  cert core-db       "DNS:core-db.dummybank.internal"
  cert engine-db     "DNS:engine-db.dummybank.internal"
  cp "$S/tls/ca.pem" "$S/engine/ca.pem"
  cp "$S/tls/ca.pem" "$S/engine-migration/ca.pem"
  gaps=$(missing)
  [[ -z $gaps ]] || fail "could not create: $(echo $gaps)"
  echo "secrets and certificates written to ./secrets"
fi

# -- configuration from the effective ports (every run) ---------------------------------------
mkdir -p "$G"
sed -e "s/\${SSO_PORT}/$SSO_PORT/g" engine/profile.template.yaml > "$G/profile.yaml"
sed -e "s/\${ENGINE_PORT}/$ENGINE_PORT/g" \
    -e "s/\${LOS_CLIENT_SECRET}/$(cat $S/los-client-secret)/" \
    -e "s/\${ENGINE_CLIENT_SECRET}/$(cat $S/customer-api-client-secret)/" \
    -e "s/\${PW_ADMIN}/$(cat $S/password-admin)/" \
    -e "s/\${PW_ADMIN2}/$(cat $S/password-admin2)/" \
    -e "s/\${PW_EDITOR}/$(cat $S/password-editor)/" \
    -e "s/\${PW_APPROVER}/$(cat $S/password-approver)/" \
    -e "s/\${PW_VIEWER}/$(cat $S/password-viewer)/" \
    bank/keycloak/realm-dummybank.template.json > "$S/realm-dummybank.json"

# Keycloak imports the realm file only while the realm does not exist yet. On an installation,
# a new console port must also be set on the realm's console client.
if [[ -f $S/PORTS ]] && [[ $(cat "$S/PORTS") != "ENGINE_PORT=$ENGINE_PORT SSO_PORT=$SSO_PORT" ]] \
    && [[ -n $(installed_data) ]]; then
  echo "NOTE: the ports changed ($(cat "$S/PORTS") -> ENGINE_PORT=$ENGINE_PORT SSO_PORT=$SSO_PORT)."
  echo "      Keycloak keeps its realm: in https://localhost:$SSO_PORT/admin/ set the client"
  echo "      'ccp-console' redirect URIs and web origins to port $ENGINE_PORT, then"
  echo "      docker compose up -d (the engine reads the new profile on start)."
fi
echo "ENGINE_PORT=$ENGINE_PORT SSO_PORT=$SSO_PORT" > "$S/PORTS"

cat > "$S/LOGINS.txt" <<EOF
Dummy bank console logins (http://127.0.0.1:$ENGINE_PORT/console/)
  it.admin        $(cat $S/password-admin)      IT administrator (everything)
  petros.it       $(cat $S/password-admin2)      second IT administrator (four-eyes on IT-owned setup)
  maria.risk      $(cat $S/password-editor)      credit risk: edits models, products, strategies
  nikos.approver  $(cat $S/password-approver)      approver: the second person (four-eyes)
  eva.viewer      $(cat $S/password-viewer)      read-only
Keycloak admin console: https://localhost:$SSO_PORT/admin/  admin / $(cat $S/keycloak-admin-password)
EOF
echo "configuration written for ENGINE_PORT=$ENGINE_PORT SSO_PORT=$SSO_PORT (.env, generated/, secrets/realm-dummybank.json)"
cat "$S/LOGINS.txt"
