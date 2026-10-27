#!/usr/bin/env bash
# One-time Vault initialisation: the operator step every real Vault needs.
# Works against kind and EKS alike (current KUBECONFIG).
#
#   1. `vault operator init` on vault-0. With KMS auto-unseal this yields
#      recovery keys (not unseal keys); the pods unseal themselves now and after
#      every restart. Keys are written to .kube/vault-init.json (mode 600,
#      gitignored). On AWS, move them to offline storage and delete the file.
#   2. With the initial root token: enable Kubernetes auth and create the
#      vault-configurer role/policy used by the GitOps configuration Job
#      (gitops/platform/vault-config).
#   3. Revoke the root token. From here on, Vault is configured from git only;
#      a new root token can be generated with the recovery keys (break-glass).
#
# Idempotent: does nothing when Vault is already initialised.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kubectl jq

NS="${VAULT_NAMESPACE:-vault}"
OUT="${VAULT_INIT_FILE:-$ROOT/.kube/vault-init.json}"
POLICY="$ROOT/gitops/platform/vault-config/files/policies/vault-configurer.hcl"

vault0() { kubectl -n "$NS" exec -i vault-0 -c vault -- "$@"; }

wait_for "vault-0 to run" 600 bash -c "[[ \$(kubectl -n $NS get pod vault-0 -o jsonpath='{.status.containerStatuses[0].started}' 2>/dev/null) == true ]]"
# `vault status` exits 2 when sealed/uninitialised; the JSON is still printed.
status="$(vault0 vault status -format=json 2>/dev/null || true)"
[[ -n "$status" ]] || die "could not read vault status from vault-0"
if [[ "$(jq -r .initialized <<<"$status")" == true ]]; then
  ok "Vault is already initialised (seal: $(jq -r .type <<<"$status"), sealed: $(jq -r .sealed <<<"$status"))"
  exit 0
fi

log "initialising Vault (auto-unseal: $(jq -r .type <<<"$status"))"
umask 077
vault0 vault operator init -recovery-shares=5 -recovery-threshold=3 -format=json > "$OUT"
chmod 600 "$OUT"
ok "recovery keys written to $OUT (5 shares, threshold 3)"
wait_for "vault-0 to unseal itself" 120 bash -c "kubectl -n $NS exec vault-0 -c vault -- vault status -format=json 2>/dev/null | jq -e '.sealed == false' >/dev/null"
ok "vault-0 unsealed by KMS"

log "bootstrapping Kubernetes auth for the configuration job, then revoking the root token"
# The token travels on stdin only (never in argv or the environment of kubectl).
{
  printf 'VAULT_TOKEN=%s\nexport VAULT_TOKEN\n' "$(jq -r .root_token "$OUT")"
  cat <<'SCRIPT'
set -e
vault auth list -format=json | grep -q '"kubernetes/"' || vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc >/dev/null
vault policy write vault-configurer - <<'POLICY' >/dev/null
SCRIPT
  cat "$POLICY"
  cat <<SCRIPT
POLICY
vault write auth/kubernetes/role/vault-configurer \\
  bound_service_account_names=vault-configurer bound_service_account_namespaces=$NS \\
  audience=vault token_policies=vault-configurer token_ttl=10m token_max_ttl=15m >/dev/null
vault token revoke -self
SCRIPT
} | vault0 sh -s
# The revoked root token is useless; keep only the recovery keys.
jq 'del(.root_token)' "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
ok "root token revoked; Vault is now configured only by the vault-config job"

for i in 1 2; do
  wait_for "vault-$i to join the Raft cluster and unseal" 300 bash -c \
    "kubectl -n $NS exec vault-$i -c vault -- vault status -format=json 2>/dev/null | jq -e '.initialized and (.sealed | not)' >/dev/null"
done
ok "Vault HA: 3 nodes initialised and unsealed"
