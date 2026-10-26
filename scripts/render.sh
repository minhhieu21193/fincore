#!/usr/bin/env bash
# Render every Argo CD Application of an environment exactly as Argo CD would
# (same charts, pinned versions, value files and injected cluster values) so
# the output can be validated offline.
#
#   scripts/render.sh kind out/kind
#   scripts/render.sh aws  out/aws     # uses gitops/ci/aws-cluster.example.yaml (fake values)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need helm yq

ENV="${1:?usage: render.sh <kind|aws> <outdir>}"
OUT="${2:?usage: render.sh <kind|aws> <outdir>}"
K8S_VERSION="${K8S_VERSION:-1.36.0}"
mkdir -p "$OUT"
rm -f "$OUT"/*.yaml

extra=()
[[ "$ENV" == aws ]] && extra=(-f "$ROOT/gitops/ci/aws-cluster.example.yaml")
helm template root "$ROOT/gitops/bootstrap/app-of-apps" -n argocd \
  -f "$ROOT/gitops/envs/$ENV/app-of-apps.yaml" ${extra[@]+"${extra[@]}"} > "$OUT/00-app-of-apps.yaml"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# chart_tgz <repo> <chart> <version>: path of the chart archive, pulled once into
# a local cache (CI caches this directory). Public registries rate-limit shared
# CI runners (public.ecr.aws answers 429), so pulls are retried with backoff.
CHART_CACHE="${CHART_CACHE:-$ROOT/.tools/helm/charts}"
chart_tgz() {
  local repo="$1" chart="$2" version="$3" dir src attempt
  dir="$CHART_CACHE/$(printf '%s' "$repo" | tr -c 'A-Za-z0-9.-' '_')/$chart/$version"
  if ! compgen -G "$dir/*.tgz" >/dev/null; then
    if [[ "$repo" == *://* ]]; then
      src=("$chart" --repo "$repo")
    else
      src=("oci://$repo/$chart")                   # OCI registry (e.g. Karpenter)
    fi
    mkdir -p "$dir"
    for attempt in 1 2 3 4 5; do
      helm pull "${src[@]}" --version "$version" -d "$dir" >&2 && break
      (( attempt == 5 )) && die "could not pull chart $chart $version from $repo"
      warn "pull of $chart $version failed (attempt $attempt), retrying in $(( attempt * 15 ))s"
      sleep $(( attempt * 15 ))
    done
  fi
  compgen -G "$dir/*.tgz" | head -1
}

for app in $(yq -N -r 'select(.kind == "Application") | .metadata.name' "$OUT/00-app-of-apps.yaml"); do
  yq "select(.kind == \"Application\" and .metadata.name == \"$app\")" "$OUT/00-app-of-apps.yaml" > "$tmp/app.yaml"
  ns="$(yq -r '.spec.destination.namespace' "$tmp/app.yaml")"
  yq '.spec.source.helm.valuesObject // .spec.sources[0].helm.valuesObject // {}' "$tmp/app.yaml" > "$tmp/inline.yaml"
  args=()

  if [[ "$(yq -r '.spec.source.path // ""' "$tmp/app.yaml")" != "" ]]; then
    path="$ROOT/$(yq -r '.spec.source.path' "$tmp/app.yaml")"
    if [[ ! -f "$path/Chart.yaml" ]]; then
      for f in "$path"/*.yaml; do printf -- '---\n'; cat "$f"; done > "$OUT/$app.yaml"   # plain manifests
      continue
    fi
    for vf in $(yq -r '.spec.source.helm.valueFiles[]' "$tmp/app.yaml"); do
      [[ -f "$path/$vf" ]] && args+=(-f "$path/$vf")   # ignoreMissingValueFiles
    done
    helm template "$app" "$path" -n "$ns" --kube-version "$K8S_VERSION" ${args[@]+"${args[@]}"} -f "$tmp/inline.yaml" > "$OUT/$app.yaml"
  else
    repo="$(yq -r '.spec.sources[0].repoURL' "$tmp/app.yaml")"
    chart="$(yq -r '.spec.sources[0].chart' "$tmp/app.yaml")"
    version="$(yq -r '.spec.sources[0].targetRevision' "$tmp/app.yaml")"
    for vf in $(yq -r '.spec.sources[0].helm.valueFiles[]' "$tmp/app.yaml"); do
      f="$ROOT/${vf#\$values/}"
      [[ -f "$f" ]] && args+=(-f "$f")
    done
    helm template "$app" "$(chart_tgz "$repo" "$chart" "$version")" -n "$ns" --kube-version "$K8S_VERSION" \
      ${args[@]+"${args[@]}"} -f "$tmp/inline.yaml" > "$OUT/$app.yaml"
  fi
done
ok "rendered $(find "$OUT" -name '*.yaml' | wc -l | tr -d ' ') files for env=$ENV into $OUT"
