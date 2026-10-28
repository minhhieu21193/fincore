#!/usr/bin/env bash
# Delete the local kind cluster (and everything in it).
#
#   scripts/kind-down.sh            # cluster only; the registry, the backup store
#                                   # (and its backups) and the local PKI are kept
#   scripts/kind-down.sh --purge    # also the registry, the backup store and the local PKI
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kind docker
kind delete cluster --name "$CLUSTER"
# Vault's recovery keys belong to the deleted cluster's Vault.
rm -f "$KUBECONFIG" "$ROOT/.kube/kind-cluster.yaml" "$ROOT/.kube/vault-init.json"
ok "kind cluster '$CLUSTER' deleted"
if [[ "${1:-}" == "--purge" ]]; then
  docker rm -f "$REGISTRY_CONTAINER" "$S3_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm fincore-registry-data fincore-s3-data >/dev/null 2>&1 || true
  rm -f "$PKI"/registry* "$PKI"/cosign.* "$PKI"/signing-config.json "$S3_CREDENTIALS" "$PKI/s3-identities.json"
  ok "registry, backup store (and every backup in it) and local PKI removed"
fi
