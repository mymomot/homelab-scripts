#!/usr/bin/env bash
# install-pmtiles.sh — Idempotent install go-pmtiles binary on LXC 511
# Council Art.15 bis C6 — SHA256 verification mandatory
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKSUMS_FILE="${REPO_ROOT}/maps/checksums/go-pmtiles.sha256"
INSTALL_TARGET="/usr/local/bin/go-pmtiles"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Extract version from checksums comment
SOURCE_URL=$(grep '^# Source:' "${CHECKSUMS_FILE}" | cut -d' ' -f3)
TAG=$(echo "${SOURCE_URL}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
VER="${TAG#v}"
ASSET_NAME="go-pmtiles_${VER}_Linux_x86_64.tar.gz"
ASSET_URL="https://github.com/protomaps/go-pmtiles/releases/download/${TAG}/${ASSET_NAME}"

echo "[install] Target version: ${TAG}"
echo "[install] Asset: ${ASSET_URL}"

# Skip if already installed at correct version
if [ -x "${INSTALL_TARGET}" ]; then
    INSTALLED_VER=$("${INSTALL_TARGET}" version 2>&1 | head -1 || echo "unknown")
    if echo "${INSTALLED_VER}" | grep -q "${VER}"; then
        echo "[install] Already installed at ${VER}, skip."
        exit 0
    fi
fi

cd "${TMP_DIR}"
echo "[install] Downloading..."
curl -fLO "${ASSET_URL}"

echo "[install] Verifying SHA256..."
EXPECTED_SHA=$(grep -v '^#' "${CHECKSUMS_FILE}" | grep "${ASSET_NAME}" | awk '{print $1}')
ACTUAL_SHA=$(sha256sum "${ASSET_NAME}" | awk '{print $1}')
if [ "${EXPECTED_SHA}" != "${ACTUAL_SHA}" ]; then
    echo "[install] FATAL: SHA256 mismatch"
    echo "  Expected: ${EXPECTED_SHA}"
    echo "  Actual:   ${ACTUAL_SHA}"
    exit 1
fi
echo "[install] SHA256 OK: ${ACTUAL_SHA}"

echo "[install] Extracting..."
tar xzf "${ASSET_NAME}"

# Le binaire dans l'archive s'appelle 'pmtiles' (pas 'go-pmtiles')
echo "[install] Installing to ${INSTALL_TARGET}..."
sudo install -o root -g root -m 0755 ./pmtiles "${INSTALL_TARGET}"

echo "[install] Verify installed binary..."
"${INSTALL_TARGET}" version

echo "[install] Done."
