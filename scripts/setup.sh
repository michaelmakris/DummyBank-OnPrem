#!/usr/bin/env bash
# One-time preparation of the dummy bank: random secrets, a private certificate authority with
# server certificates for every service, and the Keycloak realm with those secrets filled in.
# Everything lands in ./secrets (git-ignored). Run again with --force to start over.
#
#   bash scripts/setup.sh [--force]
#
# Needs: bash, openssl. Written for Git Bash on Windows, works the same on Linux/macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1   # Git Bash: keep "/CN=..." as is

S=secrets
if [[ -d $S && ${1:-} != --force ]]; then
  echo "secrets/ exists already (use --force to recreate everything)"; exit 0
fi
rm -rf "$S" && mkdir -p "$S/tls" "$S/engine"

rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }

# -- secrets: one file per secret, as a vault would mount them --------------------------------
for name in core-db-admin-password core-api-password dwh-password engine-db-admin-password \
            db-password db-migrator-password customer-api-client-secret model-api-token \
            los-client-secret keycloak-admin-password; do
  rand 32 > "$S/$name"
done
rand 48 > "$S/customer-token-key"
for user in admin admin2 editor approver viewer; do rand 16 > "$S/password-$user"; done

# The credit engine's secret directory holds only what the engine needs (least privilege).
for name in db-password db-migrator-password dwh-password customer-api-client-secret \
            customer-token-key model-api-token; do
  cp "$S/$name" "$S/engine/$name"
done

# -- private certificate authority + one certificate per service ------------------------------
openssl req -x509 -newkey rsa:3072 -nodes -days 825 -subj "/CN=Dummy Bank Internal CA" \
  -keyout "$S/tls/ca.key" -out "$S/tls/ca.pem" 2>/dev/null
cert() {  # cert <file name> <subject alt names>
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$1" -keyout "$S/tls/$1.key" \
    -out "$S/tls/$1.csr" 2>/dev/null
  printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$2" > "$S/tls/$1.ext"
  openssl x509 -req -in "$S/tls/$1.csr" -CA "$S/tls/ca.pem" -CAkey "$S/tls/ca.key" \
    -CAcreateserial -days 825 -extfile "$S/tls/$1.ext" -out "$S/tls/$1.pem" 2>/dev/null
  rm "$S/tls/$1.csr" "$S/tls/$1.ext"
}
cert sso           "DNS:sso.dummybank.internal,DNS:localhost,IP:127.0.0.1"
cert customer-data "DNS:customer-data.dummybank.internal"
cert models        "DNS:models.dummybank.internal"
cert core-db       "DNS:core-db.dummybank.internal"
cert engine-db     "DNS:engine-db.dummybank.internal"
cp "$S/tls/ca.pem" "$S/engine/ca.pem"

# -- Keycloak realm with the generated secrets ------------------------------------------------
ENGINE_PORT=$(grep -s '^ENGINE_PORT=' .env | cut -d= -f2 || true)
sed -e "s/\${ENGINE_PORT}/${ENGINE_PORT:-28080}/g" \
    -e "s/\${LOS_CLIENT_SECRET}/$(cat $S/los-client-secret)/" \
    -e "s/\${ENGINE_CLIENT_SECRET}/$(cat $S/customer-api-client-secret)/" \
    -e "s/\${PW_ADMIN}/$(cat $S/password-admin)/" \
    -e "s/\${PW_ADMIN2}/$(cat $S/password-admin2)/" \
    -e "s/\${PW_EDITOR}/$(cat $S/password-editor)/" \
    -e "s/\${PW_APPROVER}/$(cat $S/password-approver)/" \
    -e "s/\${PW_VIEWER}/$(cat $S/password-viewer)/" \
    bank/keycloak/realm-dummybank.template.json > "$S/realm-dummybank.json"

cat > "$S/LOGINS.txt" <<EOF
Dummy bank console logins (http://127.0.0.1:${ENGINE_PORT:-28080}/console/)
  it.admin        $(cat $S/password-admin)      IT administrator (everything)
  petros.it       $(cat $S/password-admin2)      second IT administrator (four-eyes on IT-owned setup)
  maria.risk      $(cat $S/password-editor)      credit risk: edits models, products, strategies
  nikos.approver  $(cat $S/password-approver)      approver: the second person (four-eyes)
  eva.viewer      $(cat $S/password-viewer)      read-only
Keycloak admin console: https://localhost:18443/admin/  admin / $(cat $S/keycloak-admin-password)
EOF
echo "secrets, certificates and realm written to ./secrets"
cat "$S/LOGINS.txt"
