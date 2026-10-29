#!/bin/sh
# Idempotent Vault configuration, applied by Argo CD on every sync.
set -eu
log() { echo "vault-config: $*"; }

VAULT_TOKEN="$(vault write -field=token auth/kubernetes/login role=vault-configurer jwt=@/var/run/secrets/vault/token)"
export VAULT_TOKEN

# Audit: every request and response (secrets HMAC'd) to stdout, collected with the pod logs.
if ! vault audit list 2>/dev/null | grep -q '^stdout/'; then
  vault audit enable -path=stdout file file_path=stdout
  log "audit device enabled"
fi

vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc >/dev/null

written=""
for f in /config/policies/*.hcl; do
  policy="$(basename "$f" .hcl)"
  vault policy write "$policy" "$f" >/dev/null
  written="$written $policy"
done
log "policies:$written"

vault write auth/kubernetes/role/vault-configurer \
  bound_service_account_names=vault-configurer bound_service_account_namespaces="$POD_NAMESPACE" \
  audience=vault token_policies=vault-configurer token_ttl=10m token_max_ttl=15m >/dev/null

# Backups: the snapshot job's service account gets the snapshot-only policy.
vault write auth/kubernetes/role/vault-snapshot \
  bound_service_account_names=vault-snapshot bound_service_account_namespaces="$POD_NAMESPACE" \
  audience=vault token_policies=vault-snapshot token_ttl=5m token_max_ttl=10m >/dev/null
log "role vault-snapshot: Raft snapshots only, sa=$POD_NAMESPACE/vault-snapshot"
# Database secrets engine.
vault secrets list | grep -q '^database/' || vault secrets enable -path=database database
conn="database/config/$DB_CONNECTION"
url="postgresql://{{username}}:{{password}}@$DB_HOST:$DB_PORT/postgres?sslmode=$DB_SSLMODE"
if ! vault read "$conn" >/dev/null 2>&1; then
  vault write "$conn" plugin_name=postgresql-database-plugin connection_url="$url" \
    username="$DB_ADMIN_ROLE" password=@/secrets/db-admin/password \
    allowed_roles="$DB_ROLES" password_authentication=scram-sha-256 >/dev/null
  # From here on only Vault knows the admin password.
  vault write -f "database/rotate-root/$DB_CONNECTION" >/dev/null
  log "database connection created and its admin password rotated"
else
  # Partial update: the (rotated) credentials are kept.
  vault write "$conn" connection_url="$url" allowed_roles="$DB_ROLES" >/dev/null
fi

for role in /config/roles/*; do
  # shellcheck disable=SC1090 # NAME, OWNER_ROLE, ... come from the role file
  . "$role"
  sed "s/OWNER_ROLE/$OWNER_ROLE/g" /config/sql/create.sql > /tmp/create.sql
  vault write "database/roles/$NAME" db_name="$DB_CONNECTION" \
    default_ttl="$DEFAULT_TTL" max_ttl="$MAX_TTL" \
    creation_statements=@/tmp/create.sql revocation_statements=@/config/sql/revoke.sql >/dev/null
  vault write "auth/kubernetes/role/$NAME" \
    bound_service_account_names="$SERVICE_ACCOUNT" bound_service_account_namespaces="$NAMESPACE" \
    audience=vault token_policies="$NAME-db" token_ttl=15m token_max_ttl=1h >/dev/null
  log "database role $NAME: owner=$OWNER_ROLE ttl=$DEFAULT_TTL max=$MAX_TTL sa=$NAMESPACE/$SERVICE_ACCOUNT"
done
log "done"
