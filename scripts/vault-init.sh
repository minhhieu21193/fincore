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
#
#   scripts/vault-init.sh --restore <raft snapshot>
#     Disaster recovery into a fresh, uninitialised Vault whose KMS key is the
#     original one (restored first): initialise it, restore the snapshot over it
#     with the temporary root token, and let it unseal with the original
#     keyring. Policies, auth, the database engine and its rotated credentials
#     all come back; the original recovery keys (kept offline) remain valid,
#     and the temporary keys and token are discarded.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kubectl jq

SNAPSHOT=""
if [[ "${1:-}" == --restore ]]; then
  SNAPSHOT="${2:?usage: $0 --restore <snapshot file>}"
  [[ -s "$SNAPSHOT" ]] || die "snapshot $SNAPSHOT is missing or empty"
fi
NS="${VAULT_NAMESPACE:-vault}"
OUT="${VAULT_INIT_FILE:-$ROOT/.kube/vault-init.json}"
POLICY="$ROOT/gitops/platform/vault-config/files/policies/vault-configurer.hcl"

vault0() { kubectl -n "$NS" exec -i vault-0 -c vault -- "$@"; }

wait_for "vault-0 to run" 600 bash -c "[[ \$(kubectl -n $NS get pod vault-0 -o jsonpath='{.status.containerStatuses[0].started}' 2>/dev/null) == true ]]"
# `vault status` exits 2 when sealed/uninitialised; the JSON is still printed.
# The container can be "started" a moment before Vault listens: poll.
vault_status() { vault0 vault status -format=json 2>/dev/null || true; }
wait_for "vault-0 to answer" 120 bash -c "kubectl -n $NS exec vault-0 -c vault -- vault status -format=json 2>/dev/null | jq -e 'has(\"initialized\")' >/dev/null"
status="$(vault_status)"
[[ -n "$status" ]] || die "could not read vault status from vault-0"
# A restore keeps the temporary init output until it succeeds, so a failed
# attempt (after init, before the snapshot is in) can be retried.
RESTORE_INIT="$ROOT/.kube/vault-restore-init.json"
if [[ "$(jq -r .initialized <<<"$status")" == true ]]; then
  [[ -z "$SNAPSHOT" || -f "$RESTORE_INIT" ]] || die "a restore needs a fresh Vault, and vault-0 is already initialised"
  ok "Vault is already initialised (seal: $(jq -r .type <<<"$status"), sealed: $(jq -r .sealed <<<"$status"))"
  exit 0
fi

if [[ -n "$SNAPSHOT" ]]; then
  log "restoring Vault from $(basename "$SNAPSHOT") ($(wc -c < "$SNAPSHOT" | tr -d ' ') bytes)"
  if [[ ! -f "$RESTORE_INIT" ]]; then
    ( umask 077; vault0 vault operator init -recovery-shares=1 -recovery-threshold=1 -format=json > "$RESTORE_INIT" )
  fi
  wait_for "the temporary Vault to unseal" 120 bash -c "kubectl -n $NS exec vault-0 -c vault -- vault status -format=json 2>/dev/null | jq -e '.sealed == false' >/dev/null"
  # kubectl exec's stdin can arrive truncated: copy, verify the checksum, retry.
  want="$(shasum -a 256 "$SNAPSHOT" | awk '{print $1}')"
  for attempt in 1 2 3; do
    vault0 sh -c 'cat > /home/vault/restore.snap' < "$SNAPSHOT" || true
    got="$(vault0 sha256sum /home/vault/restore.snap 2>/dev/null | awk '{print $1}')"
    [[ "$got" == "$want" ]] && break
    (( attempt == 3 )) && die "the snapshot did not arrive intact in vault-0 after 3 attempts"
    warn "snapshot copy into vault-0 incomplete (attempt $attempt), retrying"
    sleep 3
  done
  # The token travels on stdin only.
  { printf 'VAULT_TOKEN=%s\nexport VAULT_TOKEN\n' "$(jq -r .root_token "$RESTORE_INIT")"
    # shellcheck disable=SC2016 # expanded by the shell inside the pod
    echo 'vault operator raft snapshot restore -force /home/vault/restore.snap; rc=$?; rm -f /home/vault/restore.snap; exit $rc'
  } | vault0 sh -s
  rm -f "$RESTORE_INIT"
  ok "snapshot restored; the temporary recovery key and root token no longer exist"
  # Restart the node: after `snapshot restore -force` it keeps the temporary
  # cluster's Raft TLS identity in memory, and nodes that join later fail with
  # "tls: unrecognized name" (seen in DR drill trials). Restarted, it unseals
  # with the KMS key and serves the restored identity. During a restore Vault
  # runs this one node (restoreValues); the other two join once the hold is
  # released.
  kubectl -n "$NS" delete pod vault-0 --wait=true >/dev/null
  wait_for "vault-0 to come back unsealed with the original keyring" 300 bash -c \
    "kubectl -n $NS exec vault-0 -c vault -- vault status -format=json 2>/dev/null | jq -e '.initialized and (.sealed | not)' >/dev/null"
  ok "Vault restored on vault-0, unsealed with the original keyring"
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
