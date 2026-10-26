#!/usr/bin/env bash
# Install a pinned Trivy release after verifying its checksum (used in CI
# instead of a third-party action).
set -euo pipefail
VERSION="${1:?usage: install-trivy.sh <version>}"
OS=Linux ARCH=64bit
[[ "$(uname -s)" == Darwin ]] && OS=macOS
[[ "$(uname -m)" == arm64 || "$(uname -m)" == aarch64 ]] && ARCH=ARM64
TARBALL="trivy_${VERSION}_${OS}-${ARCH}.tar.gz"
BASE="https://github.com/aquasecurity/trivy/releases/download/v${VERSION}"
DIR="$(mktemp -d)"
curl -sSfL -o "$DIR/$TARBALL" "$BASE/$TARBALL"
curl -sSfL -o "$DIR/checksums.txt" "$BASE/trivy_${VERSION}_checksums.txt"
SHA256="sha256sum"; command -v sha256sum >/dev/null || SHA256="shasum -a 256"
(cd "$DIR" && grep " ${TARBALL}\$" checksums.txt | $SHA256 -c -)
tar -xzf "$DIR/$TARBALL" -C "$DIR" trivy
install -m 0755 "$DIR/trivy" "${INSTALL_DIR:-/usr/local/bin}/trivy" 2>/dev/null || sudo install -m 0755 "$DIR/trivy" /usr/local/bin/trivy
trivy --version | head -1
