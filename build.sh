#!/usr/bin/env bash
# =========================================================
# FS25_IncomeMod — Build & Deploy Script
#
# Usage:
#   bash build.sh           Build zip only
#   bash build.sh --deploy  Build and copy to active mods directory
# =========================================================

set -euo pipefail

MOD_NAME="FS25_IncomeMod"
ZIP_NAME="${MOD_NAME}.zip"
DEPLOY_DIR="/c/Users/tison/Documents/My Games/FarmingSimulator2025/mods"
LOG_FILE="/c/Users/tison/Documents/My Games/FarmingSimulator2025/log.txt"

# Always run from the project root regardless of where the script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Extract version from modDesc.xml
VERSION=$(grep -m1 '<version>' modDesc.xml | sed 's/.*<version>\(.*\)<\/version>.*/\1/')

echo "============================================"
echo "  ${MOD_NAME} v${VERSION}"
echo "============================================"

# Remove previous zip so we never ship a stale build
rm -f "$ZIP_NAME"

echo "Packing..."
# Use Python's zipfile to pack with forward-slash paths inside the archive.
# PowerShell's Compress-Archive uses backslashes which break FS25 mod loading.
py -c "
import zipfile, os, sys

zip_name = sys.argv[1]
include = ['modDesc.xml', 'icon.dds', 'gui', 'src']

with zipfile.ZipFile(zip_name, 'w', zipfile.ZIP_DEFLATED) as zf:
    for entry in include:
        if os.path.isfile(entry):
            zf.write(entry, entry.replace(os.sep, '/'))
        elif os.path.isdir(entry):
            for root, dirs, files in os.walk(entry):
                for fname in files:
                    full_path = os.path.join(root, fname)
                    arc_name = full_path.replace(os.sep, '/')
                    zf.write(full_path, arc_name)
" "$ZIP_NAME"

SIZE=$(du -h "$ZIP_NAME" | cut -f1)
echo "Built:  ${ZIP_NAME}  (${SIZE})"

if [[ "${1:-}" == "--deploy" ]]; then
    if [[ ! -d "$DEPLOY_DIR" ]]; then
        echo "ERROR: Deploy directory not found:"
        echo "  $DEPLOY_DIR"
        exit 1
    fi
    cp "$ZIP_NAME" "$DEPLOY_DIR/"
    echo "Deployed to: ${DEPLOY_DIR}"
    echo "Log:         ${LOG_FILE}"
fi

echo "============================================"
echo "  Done."
echo "============================================"
