#!/usr/bin/env bash
# install-static-assets.sh — Deploy /var/www/maps/ on LXC 511
# Council Art.15 bis C6 — SHA256 verification
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WWW_ROOT="/var/www/maps"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "[assets] Creating ${WWW_ROOT} structure..."
sudo mkdir -p "${WWW_ROOT}"/{vendor,sprites,fonts}
sudo chown -R caddy:caddy "${WWW_ROOT}"
sudo chmod -R 0755 "${WWW_ROOT}"

# --- 1. MapLibre GL JS bundle ---
MLB_VER="4.7.1"
echo "[assets] Downloading MapLibre GL JS ${MLB_VER}..."
cd "${TMP_DIR}"
curl -fLO "https://unpkg.com/maplibre-gl@${MLB_VER}/dist/maplibre-gl.js"
curl -fLO "https://unpkg.com/maplibre-gl@${MLB_VER}/dist/maplibre-gl.css"

EXPECTED_JS=$(grep "maplibre-gl.js$" "${REPO_ROOT}/maps/checksums/maplibre-gl.sha256" | awk '{print $1}')
EXPECTED_CSS=$(grep "maplibre-gl.css$" "${REPO_ROOT}/maps/checksums/maplibre-gl.sha256" | awk '{print $1}')
ACTUAL_JS=$(sha256sum maplibre-gl.js | awk '{print $1}')
ACTUAL_CSS=$(sha256sum maplibre-gl.css | awk '{print $1}')

[ "${EXPECTED_JS}" = "${ACTUAL_JS}" ] || { echo "FATAL maplibre-gl.js SHA mismatch"; exit 1; }
[ "${EXPECTED_CSS}" = "${ACTUAL_CSS}" ] || { echo "FATAL maplibre-gl.css SHA mismatch"; exit 1; }
echo "[assets] MapLibre SHA256 OK"

sudo install -o caddy -g caddy -m 0644 maplibre-gl.js  "${WWW_ROOT}/vendor/maplibre-gl.js"
sudo install -o caddy -g caddy -m 0644 maplibre-gl.css "${WWW_ROOT}/vendor/maplibre-gl.css"

# --- 2. OSM Liberty style + sprites ---
echo "[assets] Cloning osm-liberty repo..."
cd "${TMP_DIR}"
# Fix Auditeur P2 (2026-04-24) : on capture le commit au runtime via git rev-parse,
# pas besoin de variable hardcodée en amont. Le SHA est persisté dans la fixture.
git clone --depth 1 https://github.com/maputnik/osm-liberty.git
cd osm-liberty
ACTUAL_COMMIT=$(git rev-parse HEAD)
echo "[assets] osm-liberty pinned commit: ${ACTUAL_COMMIT}"

# Patch style.json :
#   - remplacer source URL par /tiles/planet.json (pattern réel go-pmtiles v1.30.2)
#   - retirer source externe natural_earth_shaded_relief (souveraineté offline-first)
#   - retirer les layers qui consomment natural_earth_shaded_relief
jq '.sources.openmaptiles.url = "/tiles/planet.json" |
    .glyphs = "/fonts/{fontstack}/{range}.pbf" |
    .sprite = "/sprites/osm-liberty" |
    del(.sources.natural_earth_shaded_relief) |
    .layers = [.layers[] | select(.source == null or .source != "natural_earth_shaded_relief")]' style.json > "${TMP_DIR}/style.json"

sudo install -o caddy -g caddy -m 0644 "${TMP_DIR}/style.json" "${WWW_ROOT}/style.json"

# Sprites (PNG + JSON 1x et 2x)
for f in osm-liberty.png osm-liberty.json osm-liberty@2x.png osm-liberty@2x.json; do
    [ -f "sprites/${f}" ] || { echo "FATAL: sprites/${f} missing"; exit 1; }
    sudo install -o caddy -g caddy -m 0644 "sprites/${f}" "${WWW_ROOT}/sprites/${f}"
done

# Update SHA256 fixtures with real commit
{
    echo "# OSM Liberty assets"
    echo "# Commit: ${ACTUAL_COMMIT}"
    echo "# Captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sha256sum sprites/osm-liberty.png sprites/osm-liberty@2x.png style.json | sed 's|sprites/||'
} > "${REPO_ROOT}/maps/checksums/osm-liberty.sha256"

# --- 3. OpenMapTiles fonts ---
# Correction 2026-04-24 (post P3) : le repo upstream n'inclut pas _output/ précompilé.
# Source correcte : release v2.0 GitHub (ZIP des PBF précompilés, dossiers par fontstack).
echo "[assets] Downloading OpenMapTiles fonts release v2.0..."
cd "${TMP_DIR}"
OMT_FONTS_URL="https://github.com/openmaptiles/fonts/releases/download/v2.0/v2.0.zip"
curl -fLO "${OMT_FONTS_URL}"
# Vérifier que le ZIP contient bien des PBF (sanity check strict — taille minimale 50MB)
ZIP_SIZE=$(wc -c < v2.0.zip)
if [ "${ZIP_SIZE}" -lt 50000000 ]; then
    echo "[assets] FATAL: v2.0.zip taille ${ZIP_SIZE} < 50MB — téléchargement incomplet ou asset inattendu"
    exit 1
fi
# Vérifier présence de PBF dans le ZIP
PBF_COUNT=$(unzip -l v2.0.zip 2>/dev/null | grep -c '\.pbf' || true)
if [ "${PBF_COUNT}" -lt 1000 ]; then
    echo "[assets] FATAL: v2.0.zip ne contient que ${PBF_COUNT} fichiers .pbf (attendu >1000) — format release inattendu"
    exit 1
fi
mkdir -p omt-fonts-extracted
unzip -q v2.0.zip -d omt-fonts-extracted
# Copier les fontstacks (dossiers avec PBF) dans /var/www/maps/fonts/
sudo cp -r omt-fonts-extracted/* "${WWW_ROOT}/fonts/"
sudo chown -R caddy:caddy "${WWW_ROOT}/fonts"

# --- 4. Viewer assets (index.html + maps-init.js) ---
sudo install -o caddy -g caddy -m 0644 "${REPO_ROOT}/maps/viewer/index.html"   "${WWW_ROOT}/index.html"
sudo install -o caddy -g caddy -m 0644 "${REPO_ROOT}/maps/viewer/maps-init.js" "${WWW_ROOT}/maps-init.js"

echo "[assets] Done. /var/www/maps/ contents:"
ls -la "${WWW_ROOT}/"
