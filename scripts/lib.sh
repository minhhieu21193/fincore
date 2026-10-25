# shellcheck shell=bash
# Shared helpers for FinCore scripts.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER:-fincore}"
export KUBECONFIG="${KUBECONFIG:-$ROOT/.kube/kind-config}"
# Pinned tools that are not on PATH by default (see README "Prerequisites").
[[ -d "$ROOT/.tools/bin" ]] && export PATH="$ROOT/.tools/bin:$PATH"

# Every FinCore image built for kind: <image name>:<service dir>:<cmd>
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
