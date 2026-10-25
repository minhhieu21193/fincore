#!/usr/bin/env bash
# Create (or update) the local FinCore platform on kind:
#   kind cluster (1 control plane + 3 workers in zones a/b/c) -> images ->
#   local "secrets" -> git server -> Argo CD -> root app-of-apps -> wait for Healthy.
# Safe to re-run. Never talks to AWS.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kind kubectl helm docker yq git openssl

NODE_IMAGE="kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed"
ARGOCD_CHART_VERSION="10.11.1"
mkdir -p "$ROOT/.kube"

# ---------------------------------------------------------------- cluster
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  log "creating kind cluster '$CLUSTER'"
  cfg="$ROOT/.kube/kind-cluster.yaml"
  mount="    extraMounts:
      - hostPath: $ROOT/.git
        containerPath: /fincore-git
        readOnly: true"
  {
    echo "kind: Cluster"
    echo "apiVersion: kind.x-k8s.io/v1alpha4"
    echo "name: $CLUSTER"
    echo "nodes:"
    echo "  - role: control-plane"
    echo "$mount"
    for zone in a b c; do
      echo "  - role: worker"
      echo "    labels:"
      echo "      topology.kubernetes.io/zone: ap-southeast-1$zone"
      echo "      topology.kubernetes.io/region: ap-southeast-1"
      echo "$mount"
    done
  } > "$cfg"
  kind create cluster --config "$cfg" --image "$NODE_IMAGE" --kubeconfig "$KUBECONFIG" --wait 120s
else
  log "kind cluster '$CLUSTER' exists"
  kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null
fi
ok "kubeconfig: $KUBECONFIG"

# ---------------------------------------------------------------- images
log "building and loading images"
"$ROOT/scripts/build-images.sh"

# ---------------------------------------------------------------- local secrets (stand-in for AWS Secrets Manager)
log "local secrets (generated once, never committed)"
kubectl create namespace secrets-emulator --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ensure_secret() { # name key=value...
  local name="$1"; shift
  if ! kubectl -n secrets-emulator get secret "$name" >/dev/null 2>&1; then
    local args=()
    for kv in "$@"; do args+=(--from-literal="$kv"); done
    kubectl -n secrets-emulator create secret generic "$name" "${args[@]}" >/dev/null
    ok "created secret $name"
  fi
}
rand() { openssl rand -hex 24; }
ensure_secret fincore-db-admin username=postgres "password=$(rand)"
ensure_secret fincore-payments-db "password=$(rand)"
ensure_secret fincore-ledger-db "password=$(rand)"
ensure_secret fincore-webhook-signing "secret=$(rand)"

# ---------------------------------------------------------------- git server
log "git server (serves $ROOT/.git read-only to Argo CD)"
kubectl apply -f "$ROOT/gitops/bootstrap/kind/gitserver.yaml" >/dev/null
kubectl -n gitserver rollout restart deployment/gitserver >/dev/null   # pick up a rebuilt image
kubectl -n gitserver rollout status deployment/gitserver --timeout=120s >/dev/null
ok "gitserver ready"

# ---------------------------------------------------------------- Argo CD
log "Argo CD (chart $ARGOCD_CHART_VERSION)"
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  -f "$ROOT/gitops/bootstrap/argocd/values.yaml" \
  -f "$ROOT/gitops/bootstrap/argocd/values-kind.yaml" \
  --wait --timeout 10m >/dev/null
ok "Argo CD ready"

log "root application (app-of-apps, env=kind)"
kubectl apply -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  source:
    repoURL: http://gitserver.gitserver.svc.cluster.local/fincore.git
    targetRevision: HEAD
    path: gitops/bootstrap/app-of-apps
    helm:
      valueFiles: [../../envs/kind/app-of-apps.yaml]
  syncPolicy:
    automated: { prune: true, selfHeal: true }
YAML

# ---------------------------------------------------------------- wait
log "waiting for every application to be Synced and Healthy (first run: ~5-10 min)"
all_healthy() {
  local out
  out="$(kubectl -n argocd get applications.argoproj.io -o json)" || return 1
  [[ "$(jq '.items | length' <<<"$out")" -gt 1 ]] || return 1
  [[ "$(jq '[.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")] | length' <<<"$out")" == 0 ]]
}
start=$SECONDS
until all_healthy; do
  if (( SECONDS - start > 1200 )); then
    kubectl -n argocd get applications.argoproj.io
    die "applications not healthy after 20 minutes"
  fi
  sleep 10
done
kubectl -n argocd get applications.argoproj.io
ok "FinCore is up on kind ($(( SECONDS - start ))s)"
cat <<INFO

  export KUBECONFIG=$KUBECONFIG
  Argo CD UI:     kubectl -n argocd port-forward svc/argocd-server 8081:80   (user admin)
                  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
  Rollouts UI:    kubectl argo rollouts dashboard   (http://localhost:3100)
  Payments API:   kubectl -n fincore port-forward svc/payments-api 8080:8080
  End-to-end:     make e2e
  Bad release:    make demo-bad-release
INFO
