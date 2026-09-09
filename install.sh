#!/bin/bash

set -Eeuo pipefail

readonly RAW_BASE_URL="https://raw.githubusercontent.com/solidsgroup/NewComputer/master"
readonly -a INSTALLER_FILES=(
    "new-computer-configure.sh"
    "wallpaper/solidsgroup.png"
    "wallpaper/cubes.png"
)

if [[ $EUID -ne 0 ]]; then
    echo "Run this bootstrap as root (for example: curl ... | sudo bash)." >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to download the installer." >&2
    exit 1
fi

INSTALLER_TEMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf -- "$INSTALLER_TEMP_DIR"
}
trap cleanup EXIT

mkdir -p "$INSTALLER_TEMP_DIR/wallpaper"
for relative_path in "${INSTALLER_FILES[@]}"; do
    curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 3 \
        "$RAW_BASE_URL/$relative_path" \
        --output "$INSTALLER_TEMP_DIR/$relative_path"
done

bash "$INSTALLER_TEMP_DIR/new-computer-configure.sh"
