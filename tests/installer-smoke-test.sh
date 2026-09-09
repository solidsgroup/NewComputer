#!/bin/bash

set -Eeuo pipefail

readonly REPOSITORY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly EXPECTED_UBUNTU_VERSION="${EXPECTED_UBUNTU_VERSION:?Set EXPECTED_UBUNTU_VERSION}"
readonly TEST_TEMP_DIR="$(mktemp -d)"
readonly MOCK_BIN_DIR="$TEST_TEMP_DIR/bin"
readonly COMMAND_TRACE="$TEST_TEMP_DIR/commands.log"
readonly UI_OUTPUT="$TEST_TEMP_DIR/ui.log"
readonly INTERRUPT_UI_OUTPUT="$TEST_TEMP_DIR/interrupt-ui.log"
readonly CHROME_SKIP_TRACE="$TEST_TEMP_DIR/chrome-skip-commands.log"
readonly CHROME_SKIP_UI_OUTPUT="$TEST_TEMP_DIR/chrome-skip-ui.log"

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
    curl
    debconf-set-selections
    dpkg-deb
    dpkg-query
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

assert_file_not_contains() {
    local unexpected="$1"
    local file="$2"

    if grep -Fq -- "$unexpected" "$file"; then
        printf 'Expected %s not to contain: %s\n' "$file" "$unexpected" >&2
        return 1
    fi
}

# Interrupt a mocked APT operation and verify that SIGINT cannot fall through
# to the success path. This represents pressing Ctrl+C during an active phase.
set +e
sudo env \
    "PATH=$MOCK_BIN_DIR:$PATH" \
    "CI_COMMAND_TRACE=$COMMAND_TRACE" \
    "CI_VALIDATE_APT=0" \
    "CI_INTERRUPT_ON_COMMAND=apt-get" \
    bash "$REPOSITORY_DIR/new-computer-configure.sh" \
    >"$INTERRUPT_UI_OUTPUT" 2>&1
interrupt_status=$?
set -e

if [[ $interrupt_status -ne 130 ]]; then
    printf 'Expected interrupted installer status 130, got %s.\n' \
        "$interrupt_status" >&2
    exit 1
fi
assert_file_contains "[  5%] ■ Cancelled: Refresh Ubuntu package metadata" \
    "$INTERRUPT_UI_OUTPUT"
assert_file_contains "Configuration cancelled by SIGINT" "$INTERRUPT_UI_OUTPUT"
assert_file_not_contains "[100%] ✓ Configuration complete" "$INTERRUPT_UI_OUTPUT"

# A repeat installation must not download the large Chrome package again.
: >"$CHROME_SKIP_TRACE"
sudo env \
    "PATH=$MOCK_BIN_DIR:$PATH" \
    "CI_COMMAND_TRACE=$CHROME_SKIP_TRACE" \
    "CI_VALIDATE_APT=0" \
    "CI_GOOGLE_CHROME_INSTALLED=1" \
    bash "$REPOSITORY_DIR/new-computer-configure.sh" \
    >"$CHROME_SKIP_UI_OUTPUT" 2>&1
assert_file_contains "dpkg-query" "$CHROME_SKIP_TRACE"
assert_file_not_contains "curl " "$CHROME_SKIP_TRACE"
assert_file_not_contains "/tmp/google-chrome-stable." "$CHROME_SKIP_TRACE"
assert_file_contains "[100%] ✓ Configuration complete" "$CHROME_SKIP_UI_OUTPUT"

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
assert_file_contains "[ 55%] Configure the Slick Greeter login screen" \
    /var/log/new-computer-configure.log
assert_file_contains "[ 75%] Ensure Google Chrome is installed" \
    /var/log/new-computer-configure.log

# Verify the installer requested each important external operation.
assert_trace_matches '^apt-get .* update$'
assert_trace_matches '^apt-get .* upgrade$'
assert_trace_matches \
    '^apt-get .* install .*kde-full.*lightdm.*slick-greeter.*breeze-gtk-theme.*breeze-icon-theme'
assert_file_contains \
    "curl --fail --location --silent --show-error --retry 5 --retry-delay 2 https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" \
    "$COMMAND_TRACE"
assert_trace_matches '^apt-get .* install /tmp/google-chrome-stable\..*\.deb$'
assert_trace_matches '^apt-get .* install .*clang.*clangd'
assert_trace_matches '^apt-get .* autoremove$'
assert_file_contains "systemctl enable --now snapd.socket" "$COMMAND_TRACE"
assert_file_contains "snap install slack" "$COMMAND_TRACE"
assert_file_contains "ufw allow OpenSSH" "$COMMAND_TRACE"

# File-producing portions run for real on the disposable hosted runner.
cmp "$REPOSITORY_DIR/wallpaper/solidsgroup.png" \
    /usr/share/backgrounds/solidsgroup.png
cmp "$REPOSITORY_DIR/wallpaper/cubes.png" /usr/share/backgrounds/cubes.png
assert_file_contains "WallpaperPlugin=org.kde.image" \
    /etc/xdg/kscreenlockerrc
assert_file_contains "Image=/usr/share/backgrounds/cubes.png" \
    /etc/xdg/kscreenlockerrc
assert_file_contains "greeter-session=slick-greeter" \
    /etc/lightdm/lightdm.conf.d/99-solids-group.conf
assert_file_contains "user-session=plasma" \
    /etc/lightdm/lightdm.conf.d/99-solids-group.conf
assert_file_contains "greeter-show-manual-login=true" \
    /etc/lightdm/lightdm.conf.d/99-solids-group.conf
assert_file_contains "background=/usr/share/backgrounds/solidsgroup.png" \
    /etc/lightdm/slick-greeter.conf
assert_file_contains "theme-name=Breeze-Dark" \
    /etc/lightdm/slick-greeter.conf
assert_file_contains "onscreen-keyboard=false" \
    /etc/lightdm/slick-greeter.conf
assert_file_contains "Exec=/usr/local/bin/set-default-desktop-wallpaper" \
    /etc/xdg/autostart/set-default-desktop-wallpaper.desktop
assert_file_contains 'LOCK_MARKER="$HOME/.config/.cubes-plasma-lock-screen-set"' \
    /usr/local/bin/set-default-desktop-wallpaper
assert_file_contains "kwriteconfig6 kwriteconfig5" \
    /usr/local/bin/set-default-desktop-wallpaper
bash -n /usr/local/bin/set-default-desktop-wallpaper

printf 'Installer smoke test passed on Ubuntu %s.\n' "$VERSION_ID"
