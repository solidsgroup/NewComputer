#!/bin/bash

set -Eeuo pipefail

readonly REPOSITORY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly EXPECTED_UBUNTU_VERSION="${EXPECTED_UBUNTU_VERSION:?Set EXPECTED_UBUNTU_VERSION}"
readonly TEST_TEMP_DIR="$(mktemp -d)"
readonly MOCK_BIN_DIR="$TEST_TEMP_DIR/bin"
readonly COMMAND_TRACE="$TEST_TEMP_DIR/commands.log"
readonly UI_OUTPUT="$TEST_TEMP_DIR/ui.log"

cleanup() {
    rm -rf -- "$TEST_TEMP_DIR"
}
trap cleanup EXIT

. /etc/os-release
if [[ "${VERSION_ID:-}" != "$EXPECTED_UBUNTU_VERSION" ]]; then
    printf 'Expected Ubuntu %s, runner is %s.\n' \
        "$EXPECTED_UBUNTU_VERSION" "${VERSION_ID:-unknown}" >&2
    exit 1
fi

mkdir -p "$MOCK_BIN_DIR"
: >"$COMMAND_TRACE"

readonly -a MOCKED_COMMANDS=(
    apt-get
    apt-cache
    add-apt-repository
    debconf-set-selections
    dpkg-reconfigure
    ln
    systemctl
    snap
    ufw
)

for command_name in "${MOCKED_COMMANDS[@]}"; do
    ln -s "$REPOSITORY_DIR/tests/mock-system-command" \
        "$MOCK_BIN_DIR/$command_name"
done

sudo env \
    "PATH=$MOCK_BIN_DIR:$PATH" \
    "CI_COMMAND_TRACE=$COMMAND_TRACE" \
    "CI_VALIDATE_APT=${CI_VALIDATE_APT:-0}" \
    bash "$REPOSITORY_DIR/new-computer-configure.sh" >"$UI_OUTPUT" 2>&1

assert_file_contains() {
    local expected="$1"
    local file="$2"

    if ! grep -Fq -- "$expected" "$file"; then
        printf 'Expected %s to contain: %s\n' "$file" "$expected" >&2
        return 1
    fi
}

assert_trace_matches() {
    local expected="$1"

    if ! grep -Eq -- "$expected" "$COMMAND_TRACE"; then
        printf 'Expected command trace to match: %s\n' "$expected" >&2
        return 1
    fi
}

# The non-interactive Actions log should contain the compact checklist while
# verbose command activity remains in the persistent installer log.
assert_file_contains \
    "SOLID MECHANICS RESEARCH GROUP · UBUNTU $EXPECTED_UBUNTU_VERSION SETUP" \
    "$UI_OUTPUT"
assert_file_contains "[100%] ✓ Configuration complete" "$UI_OUTPUT"
assert_file_contains "Configuration completed successfully" \
    /var/log/new-computer-configure.log
assert_file_contains "[ 62%] Install standard software and development tools" \
    /var/log/new-computer-configure.log

# Verify the installer requested each important external operation.
assert_trace_matches '^apt-get .* update$'
assert_trace_matches '^apt-get .* upgrade$'
assert_trace_matches '^apt-get .* install .*kde-full.*lightdm'
assert_trace_matches '^apt-get .* install .*clang.*clangd'
assert_trace_matches '^apt-get .* autoremove$'
assert_file_contains "systemctl enable --now snapd.socket" "$COMMAND_TRACE"
assert_file_contains "snap install slack" "$COMMAND_TRACE"
assert_file_contains "snap install overleaf" "$COMMAND_TRACE"
assert_file_contains "ufw allow OpenSSH" "$COMMAND_TRACE"

# File-producing portions run for real on the disposable hosted runner.
cmp "$REPOSITORY_DIR/wallpaper/solidsgroup.png" \
    /usr/share/backgrounds/solidsgroup.png
cmp "$REPOSITORY_DIR/wallpaper/cubes.png" /usr/share/backgrounds/cubes.png
assert_file_contains "greeter-session=lightdm-gtk-greeter" \
    /etc/lightdm/lightdm.conf.d/50-solids-group.conf
assert_file_contains "background=/usr/share/backgrounds/solidsgroup.png" \
    /etc/lightdm/lightdm-gtk-greeter.conf.d/50-solids-group.conf
assert_file_contains "Exec=/usr/local/bin/set-default-desktop-wallpaper" \
    /etc/xdg/autostart/set-default-desktop-wallpaper.desktop
bash -n /usr/local/bin/set-default-desktop-wallpaper

printf 'Installer smoke test passed on Ubuntu %s.\n' "$VERSION_ID"
