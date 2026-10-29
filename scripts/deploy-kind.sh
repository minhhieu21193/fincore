#!/usr/bin/env bash
# GitOps release on kind, mirroring what CI does on AWS:
#   build image -> load into kind -> bump the tag in gitops/envs/kind/values -> commit.
# Argo CD notices the commit and the Rollout performs the canary.
#
#   scripts/deploy-kind.sh payments-api 0.1.1
#   scripts/deploy-kind.sh payments-api 0.1.1-bad --fault-rate 0.5
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need git yq kubectl jq

[[ $# -ge 2 ]] || die "usage: $0 <image> <tag> [--fault-rate R]"
IMAGE="$1" TAG="$2"; shift 2
FAULT_RATE=0
[[ "${1:-}" == "--fault-rate" ]] && FAULT_RATE="$2"
VALUES="$ROOT/gitops/envs/kind/values/$IMAGE.yaml"
[[ -f "$VALUES" ]] || die "no kind values for $IMAGE"
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || die "working tree not clean: Argo CD deploys commits, so commit or stash first"

# One canary at a time (see wait_rollouts_settled in lib.sh); wait up to 15 min.
wait_rollouts_settled 900

"$ROOT/scripts/build-images.sh" --only "$IMAGE" --tag "$TAG" --fault-rate "$FAULT_RATE"
yq -i ".image.tag = \"$TAG\"" "$VALUES"
msg="deploy(kind): $IMAGE $TAG"
[[ "$FAULT_RATE" != 0 ]] && msg="$msg (deliberately bad build: ${FAULT_RATE} of requests fail)"
git -C "$ROOT" commit -q -m "$msg" -- "$VALUES"
ok "committed: $msg ($(git -C "$ROOT" rev-parse --short HEAD))"

# Ask Argo CD to look now instead of waiting for the next poll.
kubectl -n argocd annotate application "$IMAGE" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
# Return only once the new tag is applied: the next release's "one canary at a
# time" check must see this canary, not the state before Argo CD synced.
wait_for "Argo CD to apply $IMAGE:$TAG" 300 bash -c \
  "kubectl -n $(ns_of "$IMAGE") get rollouts.argoproj.io,deployments -o json | jq -e --arg t ':$TAG' '[.items[] | select(.metadata.name == \"$IMAGE\") | .spec.template.spec.containers[].image | select(contains(\$t))] | length > 0' >/dev/null"
ok "Argo CD applied $IMAGE:$TAG"
