#!/usr/bin/env bash
# Delete the local kind cluster (and everything in it).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kind
kind delete cluster --name "$CLUSTER"
rm -f "$KUBECONFIG" "$ROOT/.kube/kind-cluster.yaml"
ok "kind cluster '$CLUSTER' deleted"
