#!/usr/bin/env bash
# Create (or update) the local FinCore platform on kind:
#   local PKI -> kind cluster (control plane, 2 workers in zones a/b, 1 tainted
#   cardholder-data-zone worker in zone c) -> TLS registry -> signed images -> local
#   "secrets" -> git server -> Argo CD -> root app-of-apps -> Vault init -> Healthy.
# Safe to re-run. Never talks to AWS.
#
#   scripts/kind-up.sh             # create or update
#   scripts/kind-up.sh --restore   # disaster recovery into a fresh cluster from the
#                                  # backup store (scripts/dr-drill.sh): secrets
#                                  # (Velero), then Vault and PostgreSQL data, then
#                                  # everything that depends on them
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kind kubectl helm docker yq git openssl jq uuidgen

NODE_IMAGE="kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed"
ARGOCD_CHART_VERSION="10.11.1"
# Worker layout (zones of ap-southeast-1): general-purpose and cardholder-data zone.
GENERAL_ZONES=(a b)
CDE_ZONES=(c)
mkdir -p "$ROOT/.kube"
RESTORE=false
[[ "${1:-}" == --restore ]] && RESTORE=true
if $RESTORE && kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  die "--restore recovers into a new cluster; '$CLUSTER' still exists (scripts/kind-down.sh first)"
fi

# ---------------------------------------------------------------- local PKI (generated once, never committed)
log "local PKI in $PKI"
mkdir -p "$PKI" && chmod 700 "$PKI"
if [[ ! -f "$PKI/registry-ca.crt" ]]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 825 \
    -keyout "$PKI/registry-ca.key" -out "$PKI/registry-ca.crt" -subj "/CN=FinCore local registry CA" 2>/dev/null
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$PKI/registry.key" -out "$PKI/registry.csr" -subj "/CN=${REGISTRY%:*}" 2>/dev/null
  printf 'subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' "${REGISTRY%:*}" > "$PKI/registry.ext"
  openssl x509 -req -in "$PKI/registry.csr" -CA "$PKI/registry-ca.crt" -CAkey "$PKI/registry-ca.key" \
    -CAcreateserial -days 825 -extfile "$PKI/registry.ext" -out "$PKI/registry.crt" 2>/dev/null
  chmod 644 "$PKI/registry.key"   # read by the registry container (non-root)
  ok "registry CA and certificate created"
fi
if [[ ! -f "$PKI/cosign.key" ]]; then
  # Local signing key (CI signs keyless). Empty password: it never leaves this machine.
  docker run --rm -u "$(id -u)" -v "$PKI:/pki" -w /pki -e COSIGN_PASSWORD= "$COSIGN_IMAGE" generate-key-pair >/dev/null 2>&1
  # No transparency log or timestamp authority locally.
  docker run --rm -u "$(id -u)" -v "$PKI:/pki" -w /pki "$COSIGN_IMAGE" signing-config create --out signing-config.json >/dev/null 2>&1
  ok "cosign key pair created"
fi

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
    echo "containerdConfigPatches:"
    echo "  - |-"
    echo "    [plugins.\"io.containerd.grpc.v1.cri\".registry]"
    echo "      config_path = \"/etc/containerd/certs.d\""
    echo "nodes:"
    echo "  - role: control-plane"
    echo "$mount"
    # Kept small for a laptop (one Docker VM): two general-purpose workers and
    # one cardholder-data-zone worker, in three zones.
    for zone in "${GENERAL_ZONES[@]}"; do
      echo "  - role: worker"
      echo "    labels:"
      echo "      topology.kubernetes.io/zone: ap-southeast-1$zone"
      echo "      topology.kubernetes.io/region: ap-southeast-1"
      echo "      fincore.io/node-role: workload"
      echo "$mount"
    done
    # Cardholder-data zone: a dedicated, tainted node (Karpenter NodePool "cde" on AWS).
    for zone in "${CDE_ZONES[@]}"; do
      echo "  - role: worker"
      echo "    labels:"
      echo "      topology.kubernetes.io/zone: ap-southeast-1$zone"
      echo "      topology.kubernetes.io/region: ap-southeast-1"
      echo "      fincore.io/node-role: cde"
      echo "    kubeadmConfigPatches:"
      echo "      - |"
      echo "        kind: JoinConfiguration"
      echo "        nodeRegistration:"
      echo "          taints:"
      echo "            - { key: fincore.io/zone, value: cde, effect: NoSchedule }"
    done
  } > "$cfg"
  kind create cluster --config "$cfg" --image "$NODE_IMAGE" --kubeconfig "$KUBECONFIG" --wait 180s
else
  log "kind cluster '$CLUSTER' exists"
  kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null
fi
ok "kubeconfig: $KUBECONFIG"

# The control-plane node (API server, etcd, controllers; nothing else is
# scheduled there) gets at most 2 CPUs. The API server holds ~1 GB of CRD
# schemas, and its garbage-collection bursts otherwise took most of the VM for
# seconds at a time, stalling the application nodes (canary p95 failures).
docker update --cpus=2 "$CLUSTER-control-plane" >/dev/null

# ---------------------------------------------------------------- registry (stand-in for ECR)
ca_fp="$(openssl x509 -in "$PKI/registry-ca.crt" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d :)"
if [[ "$(docker inspect -f '{{index .Config.Labels "fincore.io/ca"}}' "$REGISTRY_CONTAINER" 2>/dev/null)" != "$ca_fp" ]]; then
  log "registry $REGISTRY (TLS, published on $REGISTRY_PUSH)"
  docker rm -f "$REGISTRY_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --restart=always --name "$REGISTRY_CONTAINER" --network kind \
    --label "fincore.io/ca=$ca_fp" -p "127.0.0.1:${REGISTRY_PUSH#*:}:5000" \
    -v fincore-registry-data:/var/lib/registry -v "$PKI:/certs:ro" \
    -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt -e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
    "$REGISTRY_IMAGE" >/dev/null
fi
wait_for "registry" 30 curl -sf --cacert "$PKI/registry-ca.crt" "https://$REGISTRY_PUSH/v2/"
ok "registry ready"

# ---------------------------------------------------------------- backup store (stand-in for S3)
log "backup store $S3_ENDPOINT (SeaweedFS, outside the cluster)"
if [[ ! -f "$S3_CREDENTIALS" ]]; then
  $RESTORE && die "no backup store credentials in $S3_CREDENTIALS: nothing to restore from"
  printf 'S3_ACCESS_KEY=fincore%s\nS3_SECRET_KEY=%s\n' "$(openssl rand -hex 8)" "$(openssl rand -hex 24)" > "$S3_CREDENTIALS"
  chmod 600 "$S3_CREDENTIALS"
fi
# shellcheck disable=SC1090
source "$S3_CREDENTIALS"
printf '{"identities":[{"name":"fincore-backup","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","Write","List","Tagging"]}]}\n' \
  "$S3_ACCESS_KEY" "$S3_SECRET_KEY" > "$PKI/s3-identities.json"
chmod 644 "$PKI/s3-identities.json"   # read by the store's container
if [[ "$(docker inspect -f '{{.State.Running}}' "$S3_CONTAINER" 2>/dev/null)" != true ]]; then
  docker rm -f "$S3_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --restart=always --name "$S3_CONTAINER" --network kind -p "127.0.0.1:${S3_HOST_ENDPOINT##*:}:8333" \
    -v fincore-s3-data:/data -v "$PKI/s3-identities.json:/etc/seaweedfs/s3.json:ro" \
    "$S3_IMAGE" mini -dir=/data -bucket="$S3_BUCKET" -s3.config=/etc/seaweedfs/s3.json -ip.bind=0.0.0.0 >/dev/null
fi
wait_for "backup store" 90 s3 -o /dev/null "?list-type=2&max-keys=1"
ok "backup store ready (bucket $S3_BUCKET)"

# Every node trusts the registry CA: containerd (pulls) and a CA bundle that
# Kyverno mounts to fetch signatures (gitops/envs/kind/values/kyverno.yaml).
log "node trust for $REGISTRY"
bundle="$(mktemp)"
hosts="$(mktemp)"
printf 'server = "https://%s"\n\n[host."https://%s"]\n  capabilities = ["pull", "resolve"]\n  ca = "/etc/containerd/certs.d/%s/ca.crt"\n' \
  "$REGISTRY" "$REGISTRY" "$REGISTRY" > "$hosts"
for node in $(kind get nodes --name "$CLUSTER"); do
  docker exec "$node" mkdir -p "/etc/containerd/certs.d/$REGISTRY" /etc/fincore
  docker exec -i "$node" cp /dev/stdin "/etc/containerd/certs.d/$REGISTRY/ca.crt" < "$PKI/registry-ca.crt"
  docker exec -i "$node" cp /dev/stdin "/etc/containerd/certs.d/$REGISTRY/hosts.toml" < "$hosts"
  docker exec "$node" cat /etc/ssl/certs/ca-certificates.crt > "$bundle"
  cat "$PKI/registry-ca.crt" >> "$bundle"
  docker exec -i "$node" cp /dev/stdin /etc/fincore/ca-certificates.crt < "$bundle"
  docker exec "$node" chmod 0644 /etc/fincore/ca-certificates.crt "/etc/containerd/certs.d/$REGISTRY/ca.crt" "/etc/containerd/certs.d/$REGISTRY/hosts.toml"
done
rm -f "$bundle" "$hosts"
ok "nodes trust the registry CA"

# ---------------------------------------------------------------- images
log "building, publishing and signing images"
"$ROOT/scripts/build-images.sh"

# ---------------------------------------------------------------- local secrets (stand-in for AWS Secrets Manager)
log "local secrets (generated once, never committed)"
for ns in secrets-emulator vault velero fincore-data; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
# Secrets labelled fincore.io/restore=early are what a restore brings back
# first (Velero), before anything that uses them starts.
ensure_secret() { # name key=value...
  local name="$1"; shift
  if ! kubectl -n secrets-emulator get secret "$name" >/dev/null 2>&1; then
    local args=()
    for kv in "$@"; do args+=(--from-literal="$kv"); done
    kubectl -n secrets-emulator create secret generic "$name" "${args[@]}" >/dev/null
    ok "created secret $name"
  fi
  kubectl -n secrets-emulator label --overwrite secret "$name" fincore.io/restore=early >/dev/null
}
rand() { openssl rand -hex 24; }
if ! $RESTORE; then
  ensure_secret fincore-db-admin username=postgres "password=$(rand)"
  ensure_secret fincore-payments-db "password=$(rand)"
  ensure_secret fincore-webhook-signing "secret=$(rand)"
  # Bootstrap password of Vault's database admin role; Vault rotates it on first use.
  ensure_secret fincore-vault-db-admin "password=$(rand)"

  # Seed of the local KMS emulator (kind's stand-in for the Vault unseal key in AWS KMS):
  # a random 256-bit key, generated once per cluster.
  if ! kubectl -n vault get secret local-kms-seed >/dev/null 2>&1; then
    seed="$(mktemp)"
    key_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    cat > "$seed" <<SEED
Keys:
  Symmetric:
    Aes:
      - Metadata:
          KeyId: $key_id
          Description: FinCore Vault auto-unseal (kind)
        BackingKeys:
          - $(openssl rand -hex 32)
Aliases:
  - AliasName: alias/fincore-vault-unseal
    TargetKeyId: $key_id
SEED
    kubectl -n vault create secret generic local-kms-seed --from-file=seed.yaml="$seed" >/dev/null
    rm -f "$seed"
    ok "created local KMS seed"
  fi
  kubectl -n vault label --overwrite secret local-kms-seed fincore.io/restore=early >/dev/null
fi

# Backup store credentials for Velero and the backup jobs (on AWS: Pod Identity, no keys).
kubectl -n velero create secret generic velero-s3 \
  --from-literal=cloud="$(printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' "$S3_ACCESS_KEY" "$S3_SECRET_KEY")" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
for ns in vault fincore-data; do
  kubectl -n "$ns" create secret generic backup-s3 --from-literal=access_key="$S3_ACCESS_KEY" \
    --from-literal=secret_key="$S3_SECRET_KEY" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

# The public half of the local signing key, read by Kyverno's image verification policy.
kubectl create namespace kyverno --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n kyverno create configmap fincore-cosign --from-file=cosign.pub="$PKI/cosign.pub" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# ---------------------------------------------------------------- git server
log "git server (serves $ROOT/.git read-only to Argo CD)"
kubectl apply -f "$ROOT/gitops/bootstrap/kind/gitserver.yaml" >/dev/null
kubectl -n gitserver rollout restart deployment/gitserver >/dev/null   # pick up a rebuilt image
kubectl -n gitserver rollout status deployment/gitserver --timeout=120s >/dev/null
ok "gitserver ready"

# ---------------------------------------------------------------- Argo CD
log "Argo CD (chart $ARGOCD_CHART_VERSION)"
# The chart is fetched once into the pinned chart cache, then installed from
# the local file: a restore must not depend on a chart repository being
# reachable at that moment (a DR drill trial failed on a DNS outage).
ARGOCD_TGZ="$ROOT/.tools/helm/charts/argo-cd-$ARGOCD_CHART_VERSION.tgz"
if [[ ! -f "$ARGOCD_TGZ" ]]; then
  mkdir -p "$(dirname "$ARGOCD_TGZ")"
  for attempt in 1 2 3; do
    helm pull argo-cd --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
      -d "$(dirname "$ARGOCD_TGZ")" >/dev/null && break
    (( attempt == 3 )) && die "could not download the Argo CD chart"
    warn "Argo CD chart download failed (attempt $attempt), retrying in $(( attempt * 20 ))s"
    sleep $(( attempt * 20 ))
  done
fi
helm upgrade --install argocd "$ARGOCD_TGZ" \
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
      parameters:
        - { name: restoreHold, value: "$RESTORE" }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
YAML

# ---------------------------------------------------------------- restore (--restore only)
# Argo CD holds back every component marked afterRestore (db-init, vault-config,
# the services, the backup jobs) while restoreHold is true; the rest syncs in
# its waves. Velero (first wave) brings back the secrets, then Vault and
# PostgreSQL get their data, then the hold is released.
if $RESTORE; then
  RESTORE_START=$SECONDS
  work="$(mktemp -d)"
  log "restore 1/3: secrets (Velero, from the newest cluster-state backup)"
  wait_for "Velero" 900 kubectl -n velero rollout status deployment/velero --timeout=5s
  wait_for "the backup location" 300 bash -c \
    "[[ \$(kubectl -n velero get backupstoragelocations.velero.io default -o jsonpath='{.status.phase}' 2>/dev/null) == Available ]]"
  completed_backups() {
    kubectl -n velero get backups.velero.io -l velero.io/schedule-name=velero-cluster-state -o json |
      jq -r '[.items[] | select(.status.phase == "Completed")] | sort_by(.status.completionTimestamp) | .[].metadata.name'
  }
  wait_for "Velero to list the backups in the store" 300 bash -c "kubectl -n velero get backups.velero.io -l velero.io/schedule-name=velero-cluster-state -o jsonpath='{.items[*].status.phase}' | grep -q Completed"
  backup="$(completed_backups | tail -1)"
  kubectl create -f - >/dev/null <<YAML
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: $backup-early-$(date +%s)
  namespace: velero
spec:
  backupName: $backup
  includedNamespaces: [secrets-emulator, vault]
  includedResources: [secrets]
  labelSelector:
    matchLabels: { fincore.io/restore: early }
  existingResourcePolicy: none
YAML
  wait_for "the Velero restore" 300 bash -c \
    "kubectl -n velero get restores.velero.io -o json | jq -e '[.items[] | select(.spec.backupName == \"$backup\")] | last | .status.phase == \"Completed\"' >/dev/null"
  kubectl -n vault get secret local-kms-seed >/dev/null || die "the KMS seed was not restored"
  ok "secrets restored from $backup ($(kubectl -n secrets-emulator get secrets -l fincore.io/restore=early --no-headers | wc -l | tr -d ' ') emulated Secrets Manager entries and the KMS seed)"

  log "restore 2/3: Vault (newest Raft snapshot)"
  snap_key="$(s3_latest vault/)"
  [[ -n "$snap_key" ]] || die "no Vault snapshot in the backup store"
  s3 -o "$work/vault.snap" "$snap_key"
  wait_for "vault-0 to run" 900 bash -c "[[ \$(kubectl -n vault get pod vault-0 -o jsonpath='{.status.containerStatuses[0].started}' 2>/dev/null) == true ]]"
  "$ROOT/scripts/vault-init.sh" --restore "$work/vault.snap" 2>&1 | indent
  echo "$snap_key" > "$ROOT/.kube/restored-from.txt"

  log "restore 3/3: PostgreSQL (newest pg_dumpall)"
  dump_key="$(s3_latest postgres/)"
  [[ -n "$dump_key" ]] || die "no PostgreSQL dump in the backup store"
  s3 -o "$work/postgres.sql.gz" "$dump_key"
  wait_for "PostgreSQL" 900 bash -c "[[ \$(kubectl -n fincore-data get pod postgres-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null) == true ]]"
  # The superuser already exists in the fresh database; that is the only error expected.
  errors="$(gunzip -c "$work/postgres.sql.gz" | kubectl -n fincore-data exec -i postgres-0 -- psql -U postgres -d postgres -q 2>&1 >/dev/null |
    grep ERROR | grep -v 'role "postgres" already exists' || true)"
  [[ -z "$errors" ]] || { echo "$errors" | head -10; die "the PostgreSQL restore reported errors"; }
  echo "$dump_key" >> "$ROOT/.kube/restored-from.txt"
  rm -rf "$work"
  ok "data restored from $snap_key and $dump_key"

  log "releasing the restore hold: database bootstrap, Vault configuration, services, backups"
  kubectl -n argocd patch application root --type merge \
    -p '{"spec":{"source":{"helm":{"parameters":[{"name":"restoreHold","value":"false"}]}}}}' >/dev/null
  ok "restore stages done in $(( SECONDS - RESTORE_START ))s"
fi

# ---------------------------------------------------------------- wait
log "waiting for every application to be Synced and Healthy (first run: ~5-10 min)"
all_healthy() {
  local out
  out="$(kubectl -n argocd get applications.argoproj.io -o json)" || return 1
  [[ "$(jq '.items | length' <<<"$out")" -gt 1 ]] || return 1
  [[ "$(jq '[.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")] | length' <<<"$out")" == 0 ]]
}
# Vault turns Healthy only once initialised, and later sync waves wait for it:
# initialise it (once) as soon as its first pod runs.
vault_ready_for_init() {
  [[ "$(kubectl -n vault get pod vault-0 -o jsonpath='{.status.containerStatuses[0].started}' 2>/dev/null)" == true ]]
}
vault_done=0
start=$SECONDS
until all_healthy; do
  if [[ $vault_done == 0 ]] && vault_ready_for_init; then
    "$ROOT/scripts/vault-init.sh"
    vault_done=1
  fi
  if (( SECONDS - start > 1800 )); then
    kubectl -n argocd get applications.argoproj.io
    die "applications not healthy after 30 minutes"
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
  Payments API:   kubectl -n $NS_CDE port-forward svc/payments-api 8080:8080
  End-to-end:     make e2e
  Bad release:    make demo-bad-release
  Phase 2 demos:  make demo-policies | demo-netpol | demo-rotation
  Vault recovery keys: $ROOT/.kube/vault-init.json (local only)
INFO
