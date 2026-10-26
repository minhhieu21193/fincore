#!/usr/bin/env bash
# Publish a locally built image to the kind registry the way CI publishes to ECR:
#   push -> SBOM (Syft, SPDX JSON) -> cosign signature -> cosign SBOM attestation.
# Prints the in-cluster reference by digest on stdout.
#
#   scripts/publish-image.sh fincore/ledger:0.1.0                 # signed + SBOM attestation
#   scripts/publish-image.sh fincore/notifier:0.1.0 --as fincore/notifier:unsigned --unsigned
#   scripts/publish-image.sh fincore/notifier:0.1.0 --as fincore/notifier:no-sbom --no-sbom
#
# Signing uses the local cosign key in .kube/pki (CI signs keyless with GitHub OIDC).
# No transparency log is used locally: the signing config lists no Rekor/TSA services.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need docker

SRC="${1:?usage: publish-image.sh <local image:tag> [--as <name:tag>] [--unsigned|--no-sbom]}"; shift
DEST="$SRC" SIGN=1 SBOM=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --as) DEST="$2"; shift 2 ;;
    --unsigned) SIGN=0; SBOM=0; shift ;;
    --no-sbom) SBOM=0; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -f "$PKI/cosign.key" && -f "$PKI/registry-ca.crt" ]] || die "local PKI missing; run scripts/kind-up.sh first"

docker tag "$SRC" "$REGISTRY_PUSH/$DEST"
docker push -q "$REGISTRY_PUSH/$DEST" >/dev/null || die "push of $REGISTRY_PUSH/$DEST failed"
digest="$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$REGISTRY_PUSH/$DEST" \
  | grep "^$REGISTRY_PUSH/${DEST%:*}@" | head -1 | cut -d@ -f2)"
[[ "$digest" == sha256:* ]] || die "could not determine the pushed digest of $DEST"
REF="$REGISTRY/${DEST%:*}@$digest"

# Run a supply-chain tool on the kind network (so it sees the registry as the
# cluster does) with the local PKI mounted read-only.
tool() { docker run --rm --network kind -v "$PKI:/pki:ro" -e COSIGN_PASSWORD= "$@"; }
cosign() {
  tool "$COSIGN_IMAGE" "$1" --key /pki/cosign.key --signing-config /pki/signing-config.json \
    --registry-cacert /pki/registry-ca.crt --yes "${@:2}" "$REF" >/dev/null 2>&1
}

if [[ $SIGN == 1 ]]; then
  cosign sign || die "cosign sign failed for $REF"
fi
if [[ $SBOM == 1 ]]; then
  sbom_dir="$(mktemp -d)"
  docker run --rm --network kind -v "$PKI:/pki:ro" -e SYFT_REGISTRY_CA_CERT=/pki/registry-ca.crt \
    -e SYFT_CHECK_FOR_APP_UPDATE=false "$SYFT_IMAGE" "registry:$REF" -o spdx-json -q > "$sbom_dir/sbom.spdx.json" \
    || die "syft failed for $REF"
  tool -v "$sbom_dir:/sbom:ro" "$COSIGN_IMAGE" attest --key /pki/cosign.key --signing-config /pki/signing-config.json \
    --registry-cacert /pki/registry-ca.crt --yes --type spdxjson --predicate /sbom/sbom.spdx.json "$REF" >/dev/null 2>&1 \
    || die "cosign attest failed for $REF"
  packages="$(jq '.packages | length' "$sbom_dir/sbom.spdx.json")"
  rm -f "$sbom_dir/sbom.spdx.json"; rmdir "$sbom_dir"
fi

state="unsigned"
[[ $SIGN == 1 ]] && state="signed"
[[ $SBOM == 1 ]] && state="$state, SBOM attested ($packages packages)"
ok "published $REGISTRY/$DEST ($state)" >&2
echo "$REF"
