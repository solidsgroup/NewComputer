#!/bin/bash

set -Eeuo pipefail

readonly REPOSITORY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TEST_TEMP_DIR="$(mktemp -d)"
readonly TEST_HOME="$TEST_TEMP_DIR/home with spaces"
readonly USER_TEXTEXT="$TEST_HOME/.config/inkscape/extensions/textext"
readonly BACKUP_ROOT="$TEST_HOME/.config/inkscape/disabled-extensions"

cleanup() {
    rm -rf -- "$TEST_TEMP_DIR"
}
trap cleanup EXIT

mkdir -p "$USER_TEXTEXT"
printf '%s\n' '<inkscape-extension id="org.inkscape.effect.textext"/>' \
    >"$USER_TEXTEXT/textext.inx"
printf '%s\n' '# legacy Python package' >"$USER_TEXTEXT/__init__.py"
printf '%s\n' '\usepackage{amsmath}' >"$USER_TEXTEXT/default_packages.tex"

"$REPOSITORY_DIR/inkscape/disable-duplicate-textext" "$TEST_HOME"

[[ ! -e "$USER_TEXTEXT/textext.inx" ]]
[[ ! -e "$USER_TEXTEXT/__init__.py" ]]
grep -Fxq '\usepackage{amsmath}' "$USER_TEXTEXT/default_packages.tex"

mapfile -t backups < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d)
[[ ${#backups[@]} -eq 1 ]]
[[ -f "${backups[0]}/textext.inx" ]]
[[ -f "${backups[0]}/__init__.py" ]]
grep -Fxq '\usepackage{amsmath}' "${backups[0]}/default_packages.tex"

# A repeat run must leave the preserved preamble and backup untouched.
"$REPOSITORY_DIR/inkscape/disable-duplicate-textext" "$TEST_HOME"
mapfile -t repeated_backups < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d)
[[ ${#repeated_backups[@]} -eq 1 ]]
grep -Fxq '\usepackage{amsmath}' "$USER_TEXTEXT/default_packages.tex"

printf 'TexText duplicate-extension migration tests passed.\n'
