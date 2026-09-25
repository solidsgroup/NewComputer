#!/bin/bash

set -Eeuo pipefail

readonly REPOSITORY="solidsgroup/NewComputer"
readonly BRANCH="master"
readonly COMMIT_FEED_URL="https://github.com/$REPOSITORY/commits/$BRANCH.atom"
readonly -a INSTALLER_FILES=(
    "new-computer-configure.sh"
    "kde/set-solids-kde-settings"
    "kde/inkscape-with-local-menu"
    "visit/install-visit-binaries"
    "slack/install-slack-math"
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

# Mutable raw.githubusercontent.com branch URLs can remain cached for five
# minutes after a push. Resolve the branch through GitHub's uncached Atom feed,
# then download every file from the resulting immutable commit URL.
COMMIT_SHA="$(
    curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 3 \
        "$COMMIT_FEED_URL" |
        sed -n 's|.*Grit::Commit/\([0-9a-f]\{40\}\)</id>.*|\1|p' |
        sed -n '1p'
)"

if [[ ${#COMMIT_SHA} -ne 40 || "$COMMIT_SHA" == *[!0-9a-f]* ]]; then
    echo "Unable to resolve the latest $BRANCH commit from GitHub." >&2
    exit 1
fi

readonly COMMIT_SHA
readonly RAW_BASE_URL="https://raw.githubusercontent.com/$REPOSITORY/$COMMIT_SHA"
printf 'Downloading installer revision %.12s.\n' "$COMMIT_SHA"

INSTALLER_TEMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf -- "$INSTALLER_TEMP_DIR"
}
trap cleanup EXIT

mkdir -p \
    "$INSTALLER_TEMP_DIR/kde" \
    "$INSTALLER_TEMP_DIR/visit" \
    "$INSTALLER_TEMP_DIR/slack" \
    "$INSTALLER_TEMP_DIR/wallpaper"
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
