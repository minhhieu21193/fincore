#!/usr/bin/env bash
# Build FinCore images and load them into the kind cluster.
#
#   scripts/build-images.sh                      # all images, tags from gitops/envs/kind/values
#   scripts/build-images.sh --only payments-api --tag 0.1.1
#   scripts/build-images.sh --only payments-api --tag 0.1.1-bad --fault-rate 0.5   # deliberately bad build
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ONLY="" TAG="" FAULT_RATE="0" LOAD=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --fault-rate) FAULT_RATE="$2"; shift 2 ;;
    --no-load) LOAD=0; shift ;;
    --gitserver) ONLY="gitserver"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
need docker yq
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"

load() {
  if [[ $LOAD == 1 ]]; then
    local out
    out="$(kind load docker-image --name "$CLUSTER" "$1" 2>&1)" || { echo "$out" >&2; die "kind load failed for $1"; }
    ok "loaded $1 into kind/$CLUSTER"
  fi
}

if [[ "$ONLY" == "gitserver" || -z "$ONLY" ]]; then
  docker build -q -f "$ROOT/build/gitserver.Dockerfile" -t fincore/gitserver:local "$ROOT" >/dev/null
  ok "built fincore/gitserver:local"
  load fincore/gitserver:local
  [[ "$ONLY" == "gitserver" ]] && exit 0
fi

for spec in "${IMAGES[@]}"; do
  IFS=: read -r name svc cmd <<<"$spec"
  [[ -n "$ONLY" && "$ONLY" != "$name" ]] && continue
  tag="${TAG:-$(kind_tag "$name")}"
  image="fincore/$name:$tag"
  docker build -q -f "$ROOT/build/Dockerfile" \
    --build-arg SERVICE="$svc" --build-arg CMD="$cmd" \
    --build-arg VERSION="$tag" --build-arg COMMIT="$COMMIT" --build-arg FAULT_RATE="$FAULT_RATE" \
    -t "$image" "$ROOT" >/dev/null
  ok "built $image (fault_rate=$FAULT_RATE)"
  load "$image"
done
