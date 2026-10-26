#!/usr/bin/env bash
# Convert every CustomResourceDefinition found in rendered manifests into the
# JSON schemas kubeconform expects ({group}/{kind}_{version}.json), so custom
# resources are validated against the exact CRD versions our pinned charts ship.
# Objects are closed (additionalProperties: false) unless the CRD says
# x-kubernetes-preserve-unknown-fields, which makes typos fail like in strict mode.
#
#   scripts/ci/crd-schemas.sh <rendered dir>... <out dir>
set -euo pipefail
need() { command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 1; }; }
need yq
need jq

[[ $# -ge 2 ]] || { echo "usage: $0 <rendered dir>... <out dir>" >&2; exit 2; }
OUT="${*: -1}"
mkdir -p "$OUT"

count=0
for dir in "${@:1:$#-1}"; do
  for f in "$dir"/*.yaml; do
    # One JSON object per line: group, lowercase kind, version, schema.
    # shellcheck disable=SC2016 # $s is a yq variable
    while IFS= read -r line; do
      group="$(jq -r .group <<<"$line")"
      kind="$(jq -r .kind <<<"$line")"
      version="$(jq -r .version <<<"$line")"
      mkdir -p "$OUT/$group"
      jq '.schema | walk(
            if type == "object" and has("properties") and (has("additionalProperties") | not)
               and ((."x-kubernetes-preserve-unknown-fields" // false) | not)
            then . + {additionalProperties: false} else . end)' <<<"$line" > "$OUT/$group/${kind}_${version}.json"
      count=$((count + 1))
    done < <(yq -o=json -I=0 'select(.kind == "CustomResourceDefinition") |
               .spec as $s | $s.versions[] | select(.schema.openAPIV3Schema != null) |
               {"group": $s.group, "kind": ($s.names.kind | downcase), "version": .name, "schema": .schema.openAPIV3Schema}' "$f")
  done
done
echo "generated $count CRD schemas into $OUT" >&2
