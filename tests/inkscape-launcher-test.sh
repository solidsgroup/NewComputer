#!/bin/bash

set -Eeuo pipefail
readonly REPOSITORY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Capture exec without opening a GUI. This exercises the real launcher with
# each desktop/session combination and verifies arguments survive unchanged.
check_launch() (
    export XDG_CURRENT_DESKTOP="$1" XDG_SESSION_TYPE="$2"
    unset GDK_BACKEND UBUNTU_MENUPROXY
    expected_backend="$3"
    expected_proxy="$4"
    exec() {
        [[ "${GDK_BACKEND:-unset}" == "$expected_backend" ]]
        [[ "${UBUNTU_MENUPROXY:-unset}" == "$expected_proxy" ]]
        [[ $# == 3 && "$1" == /usr/bin/inkscape && "$2" == '--' &&
           "$3" == '/tmp/drawing with spaces.svg' ]]
    }
    source "$REPOSITORY_DIR/kde/inkscape-with-local-menu" -- '/tmp/drawing with spaces.svg'
)

check_launch KDE wayland x11 0
check_launch ubuntu:KDE wayland x11 0
check_launch KDE x11 unset 0
check_launch GNOME wayland unset unset
check_launch '' '' unset unset
printf 'Inkscape launcher tests passed.\n'
