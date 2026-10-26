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

# wait_for <description> <timeout seconds> <command...>
wait_for() {
  local what="$1" timeout="$2"; shift 2
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start > timeout )) && die "timed out after ${timeout}s waiting for: $what"
    sleep 3
  done
}
