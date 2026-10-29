# shellcheck shell=bash
# shellcheck disable=SC2034 # the settings below are used by the scripts that source this file
# Shared helpers for FinCore scripts.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER:-fincore}"
export KUBECONFIG="${KUBECONFIG:-$ROOT/.kube/kind-config}"
# Pinned tools that are not on PATH by default (see README "Prerequisites").
[[ -d "$ROOT/.tools/bin" ]] && export PATH="$ROOT/.tools/bin:$PATH"
# Hermetic Helm repository config: never depend on (or modify) the user's global repos.
export HELM_REPOSITORY_CONFIG="$ROOT/.tools/helm/repositories.yaml"
export HELM_REPOSITORY_CACHE="$ROOT/.tools/helm/cache"
mkdir -p "$ROOT/.tools/helm/cache"

# Local OCI registry, the kind stand-in for ECR. Nodes, Kyverno and the signing
# containers reach it as $REGISTRY on the "kind" Docker network; the host pushes
# through the published port. TLS from a local CA, like any real registry.
REGISTRY="fincore-registry:5000"
REGISTRY_PUSH="localhost:5001"
REGISTRY_CONTAINER="fincore-registry"
REGISTRY_IMAGE="registry:3.1.2@sha256:01cd312e67026f06f5d89c3e133a4a9adc7cb9eeb9b1194e0b2954dfd770efd2"
# Locally generated key material (registry CA, cosign key pair). Gitignored, never committed.
PKI="$ROOT/.kube/pki"
# Supply-chain tools run as pinned containers, so nothing extra is installed on the host.
COSIGN_IMAGE="ghcr.io/sigstore/cosign/cosign:v3.1.4@sha256:0f06154836d2de34f887a5c273506d52ca43edaa1d9e53e6510fa78a48f69c2d"
SYFT_IMAGE="anchore/syft:v1.55.0@sha256:4cc92b64ca74ffca4c94d4c8fcc01f217731375300be14d0b6eeb2e82eaa110a"
# Backup store, the kind stand-in for S3: SeaweedFS in a container outside the
# cluster (on the "kind" network), so backups survive the cluster's deletion.
# Pods reach it as $S3_ENDPOINT; the host through the published port.
S3_CONTAINER="fincore-s3"
S3_IMAGE="chrislusf/seaweedfs:4.51@sha256:f7a49e3f3972ebed5be2ed4befa4a0c68eb7bdddba6e692d42729ceb545134b8"
S3_ENDPOINT="http://fincore-s3:8333"
S3_HOST_ENDPOINT="http://127.0.0.1:8333"
S3_BUCKET="fincore-backups"
S3_CREDENTIALS="$PKI/s3-credentials.env"   # S3_ACCESS_KEY / S3_SECRET_KEY, generated once
# Namespaces: the cardholder-data zone and everything else.
NS_CDE="fincore-cde"
NS_APP="fincore"

# Every FinCore image built for kind: <image name>:<service dir>:<cmd>
# shellcheck disable=SC2034 # used by scripts that source this file
IMAGES=(
  "payments-api:payments-api:payments-api"
  "ledger:ledger:ledger"
  "notifier:notifier:notifier"
  "webhook-sink:notifier:webhook-sink"
)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m ✘\033[0m %s\n' "$*" >&2; exit 1; }

# indent: prefix every line of stdin, for nested script output.
indent() { local l; while IFS= read -r l; do printf '   %s\n' "$l"; done; }

need() {
  local t
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t (see README prerequisites)"; done
}

# ns_of <service>: the namespace a FinCore service runs in.
ns_of() {
  case "$1" in
    payments-api|ledger) echo "$NS_CDE" ;;
    *) echo "$NS_APP" ;;
  esac
}

# kind_tag <image>: the tag currently declared for the image in the kind env.
kind_tag() {
  yq -r '.image.tag' "$ROOT/gitops/envs/kind/values/$1.yaml"
}

# rollouts_settled: every Argo Rollout in the cluster is Healthy and fully
# promoted (no canary in progress, paused or aborted).
rollouts_settled() {
  kubectl get rollouts.argoproj.io -A -o json | jq -e '
    [.items[] | select(.status.phase != "Healthy" or .status.currentPodHash != .status.stableRS)]
    | length == 0' >/dev/null
}

# wait_rollouts_settled [timeout]: on kind, never start a release while another
# canary is running: overlapping canaries share one small CPU budget and skew
# each other's latency analysis.
wait_rollouts_settled() {
  local timeout="${1:-900}" start=$SECONDS
  until rollouts_settled; do
    if (( SECONDS - start > timeout )); then
      kubectl get rollouts.argoproj.io -A
      die "a rollout is still in progress after ${timeout}s; not starting another release"
    fi
    if (( SECONDS - start == 0 )) || (( (SECONDS - start) % 60 < 5 )); then
      log "waiting for in-progress rollouts to finish before releasing"
      kubectl get rollouts.argoproj.io -A --no-headers | awk '{printf "   %s/%s\n", $1, $2}'
    fi
    sleep 5
  done
}

# wait_for <description> <timeout seconds> <command...>
wait_for() {
  local what="$1" timeout="$2"; shift 2
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start > timeout )) && die "timed out after ${timeout}s waiting for: $what"
    sleep 3
  done
}

# s3 <curl args...> <path>: signed request to the local backup store from the host.
s3() {
  # shellcheck disable=SC1090
  source "$S3_CREDENTIALS"
  curl -sf --aws-sigv4 "aws:amz:us-east-1:s3" --user "$S3_ACCESS_KEY:$S3_SECRET_KEY" "${@:1:$#-1}" "$S3_HOST_ENDPOINT/$S3_BUCKET/${!#}"
}
# s3_latest <prefix>: key of the newest object under prefix (keys embed a UTC timestamp).
s3_latest() {
  s3 "?list-type=2&prefix=$1" | grep -o '<Key>[^<]*</Key>' | sed 's/<[^>]*>//g' | sort | tail -1
}

# tf_profile_args: sets TF_PROFILE_ARGS to the extra -var-file for FINCORE_PROFILE
# (terraform/envs/demo/profiles/<name>.tfvars). up.sh and down.sh must agree,
# so both read the same variable.
TF_PROFILE_ARGS=()
tf_profile_args() {
  TF_PROFILE_ARGS=()
  [[ -z "${FINCORE_PROFILE:-}" ]] && return 0
  local f="profiles/$FINCORE_PROFILE.tfvars"
  [[ -f "$ROOT/terraform/envs/demo/$f" ]] || die "unknown profile $FINCORE_PROFILE (no terraform/envs/demo/$f)"
  TF_PROFILE_ARGS=("-var-file=$f")
}
