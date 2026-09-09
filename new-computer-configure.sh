#!/bin/bash

set -Eeuo pipefail

#
# This is a Solids Group script to do routine update and setup of new computers.
# Run with sudo; after sudo authentication, no further input is required.
# This script is stored in the "Web" folder on Google Drive.
#

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOGIN_WALLPAPER_SOURCE="$SCRIPT_DIR/wallpaper/solidsgroup.png"
DESKTOP_WALLPAPER_SOURCE="$SCRIPT_DIR/wallpaper/cubes.png"
LOG_FILE="/var/log/new-computer-configure.log"
FAILED_LINE="unknown"
PROGRESS_PERCENT=0
UI_CURRENT_STEP=-1
UI_STATE="running"

readonly C0=$'\033[38;2;31;119;180m'
readonly C1=$'\033[38;2;255;127;14m'
readonly UI_BOLD=$'\033[1m'
readonly UI_DIM=$'\033[2m'
readonly UI_RESET=$'\033[0m'

readonly -a UI_STEPS=(
    "Refresh Ubuntu package metadata"
    "Upgrade installed Ubuntu packages"
    "Check required Ubuntu repositories"
    "Install KDE Plasma and LightDM"
    "Install fonts"
    "Install desktop and login wallpapers"
    "Configure the LightDM login screen"
    "Install standard software and development tools"
    "Install the Clang toolchain"
    "Start Snap support"
    "Install Slack"
    "Install Overleaf"
    "Configure remote SSH access"
    "Remove unneeded packages"
)

if [[ $EUID -ne 0 ]]; then
    echo "Run this script as root: sudo $0"
    exit 1
fi

for required_file in "$LOGIN_WALLPAPER_SOURCE" "$DESKTOP_WALLPAPER_SOURCE"; do
    if [[ ! -r "$required_file" ]]; then
        echo "Required file not found: $required_file"
        exit 1
    fi
done

. /etc/os-release
case "${VERSION_ID:-}" in
    24.04|26.04)
        ;;
    *)
        echo "Unsupported Ubuntu release: ${VERSION_ID:-unknown}. Expected 24.04 or 26.04."
        exit 1
        ;;
esac

exec 9>/run/lock/new-computer-configure.lock
if ! flock -n 9; then
    echo "Another copy of this installer is already running."
    exit 1
fi

touch "$LOG_FILE"

# Keep the interface on the original stdout while sending verbose command
# output only to the persistent log. Under systemd, fd 3 is captured by the
# journal and receives a compact, non-interactive version of the checklist.
exec 3>&1
exec >>"$LOG_FILE" 2>&1
printf '\n===== Solids Group setup started %s =====\n' "$(date --iso-8601=seconds)"

UI_IS_TTY=false
if [[ -t 3 && "${TERM:-dumb}" != "dumb" ]]; then
    UI_IS_TTY=true
fi

UI_USE_COLOR=false
if [[ "$UI_IS_TTY" == true && -z "${NO_COLOR:-}" ]]; then
    UI_USE_COLOR=true
fi

ui_color() {
    if [[ "$UI_USE_COLOR" == true ]]; then
        printf '%s' "$1"
    fi
    return 0
}

render_ui() {
    local blue
    local orange
    local bold
    local dim
    local reset
    local completed=0
    local filled
    local empty
    local completed_bar
    local remaining_bar
    local index
    local label

    [[ "$UI_IS_TTY" == true ]] || return 0

    blue="$(ui_color "$C0")"
    orange="$(ui_color "$C1")"
    bold="$(ui_color "$UI_BOLD")"
    dim="$(ui_color "$UI_DIM")"
    reset="$(ui_color "$UI_RESET")"

    if [[ "$UI_STATE" == "succeeded" ]]; then
        completed=${#UI_STEPS[@]}
    elif (( UI_CURRENT_STEP >= 0 )); then
        completed=$UI_CURRENT_STEP
    fi

    filled=$((PROGRESS_PERCENT * 30 / 100))
    empty=$((30 - filled))
    printf -v completed_bar '%*s' "$filled" ''
    printf -v remaining_bar '%*s' "$empty" ''
    completed_bar="${completed_bar// /━}"
    remaining_bar="${remaining_bar// /─}"

    # Redraw in place so package installation never scrolls the checklist away.
    printf '\033[2J\033[H' >&3
    printf '  %s◆%s  %sSOLID MECHANICS%s\n' "$blue" "$reset" "$bold" "$reset" >&3
    printf '     %sRESEARCH GROUP%s  %s·  UBUNTU %s SETUP%s\n' \
        "$orange" "$reset" "$dim" "$VERSION_ID" "$reset" >&3
    printf '  %s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' \
        "$blue" "$reset" >&3
    printf '  %s%s%s%s%s  %3d%%  %d/%d complete\n\n' \
        "$blue" "$completed_bar" "$reset" "$dim" "$remaining_bar" \
        "$PROGRESS_PERCENT" "$completed" "${#UI_STEPS[@]}" >&3

    for index in "${!UI_STEPS[@]}"; do
        label="${UI_STEPS[$index]}"
        if [[ "$UI_STATE" == "succeeded" || $index -lt $UI_CURRENT_STEP ]]; then
            printf '  %s✓%s  %s\n' "$blue" "$reset" "$label" >&3
        elif [[ "$UI_STATE" == "failed" && $index -eq $UI_CURRENT_STEP ]]; then
            printf '  %s×%s  %s%s%s\n' "$orange" "$reset" "$bold" "$label" "$reset" >&3
        elif [[ "$UI_STATE" == "running" && $index -eq $UI_CURRENT_STEP ]]; then
            printf '  %s●%s  %s%s%s\n' "$orange" "$reset" "$bold" "$label" "$reset" >&3
        else
            printf '  %s○  %s%s\n' "$dim" "$label" "$reset" >&3
        fi
    done

    printf '\n' >&3
    case "$UI_STATE" in
        succeeded)
            printf '  %s✓ Setup complete%s  ·  Reboot recommended\n' \
                "$blue" "$reset" >&3
            ;;
        failed)
            printf '  %s× Setup stopped near line %s%s  ·  See the log below\n' \
                "$orange" "$FAILED_LINE" "$reset" >&3
            ;;
        *)
            printf '  %s● Working%s  ·  Detailed activity is hidden\n' \
                "$orange" "$reset" >&3
            ;;
    esac
    printf '  %sLog: %s%s\n' "$dim" "$LOG_FILE" "$reset" >&3
}

show_progress() {
    local percent="$1"
    local message="$2"

    if (( percent < 0 || percent > 100 )); then
        echo "Invalid progress percentage: $percent" >&2
        return 1
    fi

    PROGRESS_PERCENT="$percent"
    printf '\n[%3d%%] %s\n' "$percent" "$message"

    if (( percent == 0 )); then
        UI_CURRENT_STEP=-1
    elif (( percent == 100 )); then
        UI_CURRENT_STEP=-1
        UI_STATE="succeeded"
    else
        UI_CURRENT_STEP=$((UI_CURRENT_STEP + 1))
        if (( UI_CURRENT_STEP >= ${#UI_STEPS[@]} )); then
            echo "Checklist has fewer entries than installer steps." >&2
            return 1
        fi
        # Keep the declared checklist honest if a phase label changes later.
        if [[ "${UI_STEPS[$UI_CURRENT_STEP]}" != "$message" ]]; then
            echo "Checklist mismatch: expected '${UI_STEPS[$UI_CURRENT_STEP]}', got '$message'." >&2
            return 1
        fi
    fi

    if [[ "$UI_IS_TTY" == true ]]; then
        render_ui
    elif (( percent == 0 )); then
        printf 'SOLID MECHANICS RESEARCH GROUP · UBUNTU %s SETUP\n' \
            "$VERSION_ID" >&3
        printf 'Detailed activity: %s\n' "$LOG_FILE" >&3
    elif (( percent == 100 )); then
        printf '[%3d%%] ✓ %s\n' "$percent" "$message" >&3
    else
        printf '[%3d%%] ● %s\n' "$percent" "$message" >&3
    fi
}

trap 'FAILED_LINE=$LINENO' ERR
finish() {
    local exit_status=$?

    trap - EXIT

    if [[ $exit_status -eq 0 ]]; then
        echo "Configuration completed successfully at $(date --iso-8601=seconds)."
        echo "A reboot is recommended. Log: $LOG_FILE"
        if [[ "$UI_STATE" != "succeeded" ]]; then
            PROGRESS_PERCENT=100
            UI_CURRENT_STEP=-1
            UI_STATE="succeeded"
            render_ui
        fi
        if [[ "$UI_IS_TTY" != true ]]; then
            printf 'Configuration completed successfully. Reboot recommended.\n' >&3
        fi
    else
        echo "Configuration failed near line $FAILED_LINE with status $exit_status."
        echo "Installer stopped at approximately $PROGRESS_PERCENT%."
        echo "Review the log at $LOG_FILE"
        UI_STATE="failed"
        render_ui
        if [[ "$UI_IS_TTY" != true ]]; then
            printf 'Configuration failed near line %s (status %s). Log: %s\n' \
                "$FAILED_LINE" "$exit_status" "$LOG_FILE" >&3
        fi
    fi

    exit "$exit_status"
}
trap finish EXIT

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1

APT_GET=(
    apt-get
    -y
    -o Acquire::Retries=5
    -o DPkg::Lock::Timeout=600
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
)

echo "Starting unattended configuration for Ubuntu $VERSION_ID."
echo "Progress is being logged to $LOG_FILE"
show_progress 0 "Starting configuration"

# basic upgrade and update
show_progress 5 "Refresh Ubuntu package metadata"
"${APT_GET[@]}" update
show_progress 12 "Upgrade installed Ubuntu packages"
"${APT_GET[@]}" upgrade

# kde-full and several supporting packages are in Universe. Enable it when a
# minimal Ubuntu installation does not already provide it.
show_progress 18 "Check required Ubuntu repositories"
if ! apt-cache show kde-full >/dev/null 2>&1; then
    "${APT_GET[@]}" install software-properties-common
    add-apt-repository -y universe
    "${APT_GET[@]}" update
fi

# Install the complete KDE desktop and use LightDM's standard GTK greeter.
# Preseeding the display-manager choice keeps this install non-interactive.
# Ubuntu's display-manager package scripts preserve an existing selection, so
# also update the authoritative file explicitly after installing LightDM. This
# keeps that file and systemd's display-manager.service link in agreement.
show_progress 22 "Install KDE Plasma and LightDM"
echo "shared shared/default-x-display-manager select lightdm" | debconf-set-selections
"${APT_GET[@]}" install \
    kde-full \
    lightdm \
    lightdm-gtk-greeter
printf '%s\n' /usr/sbin/lightdm > /etc/X11/default-display-manager
echo "shared shared/default-x-display-manager select lightdm" | debconf-set-selections
dpkg-reconfigure lightdm
ln -sfn /lib/systemd/system/lightdm.service \
    /etc/systemd/system/display-manager.service
systemctl daemon-reload

# Jetbrains font
show_progress 42 "Install fonts"
"${APT_GET[@]}" install fonts-jetbrains-mono elpa-ligature


# Install the login and desktop wallpapers.
show_progress 47 "Install desktop and login wallpapers"
install -Dm644 "$LOGIN_WALLPAPER_SOURCE" /usr/share/backgrounds/solidsgroup.png
install -Dm644 "$DESKTOP_WALLPAPER_SOURCE" /usr/share/backgrounds/cubes.png

# Apply cubes.png once per user for each desktop environment they use. Keeping
# a marker per environment makes this a default without overriding later user
# changes. The Plasma branch applies the image to every desktop and display.
rm -f /usr/local/bin/set-solids-plasma-wallpaper \
      /etc/xdg/autostart/set-solids-plasma-wallpaper.desktop

cat <<'EOF' > /usr/local/bin/set-default-desktop-wallpaper
#!/bin/bash

WALLPAPER="/usr/share/backgrounds/cubes.png"
DESKTOP_NAME="${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-unknown}}"
SESSION_KEY="$(printf '%s' "$DESKTOP_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-')"
MARKER="$HOME/.config/.cubes-wallpaper-set-${SESSION_KEY:-unknown}"

[[ -e "$MARKER" ]] && exit 0

mark_complete() {
    mkdir -p "$(dirname -- "$MARKER")"
    touch "$MARKER"
}

set_plasma_wallpaper() {
    local plasma_script
    local qdbus_command

    plasma_script='var ds = desktops(); for (var i = 0; i < ds.length; i++) { ds[i].wallpaperPlugin = "org.kde.image"; ds[i].currentConfigGroup = ["Wallpaper", "org.kde.image", "General"]; ds[i].writeConfig("Image", "file:///usr/share/backgrounds/cubes.png"); }'

    for attempt in {1..20}; do
        if command -v plasma-apply-wallpaperimage >/dev/null 2>&1 && \
           plasma-apply-wallpaperimage "$WALLPAPER"; then
            return 0
        fi

        for qdbus_command in qdbus qdbus-qt5 qdbus6; do
            if command -v "$qdbus_command" >/dev/null 2>&1 && \
               "$qdbus_command" org.kde.plasmashell /PlasmaShell \
                   org.kde.PlasmaShell.evaluateScript "$plasma_script"; then
                return 0
            fi
        done

        sleep 2
    done

    return 1
}

set_gsettings_uri() {
    local schema="$1"

    if ! command -v gsettings >/dev/null 2>&1 || \
       ! gsettings list-schemas | grep -Fqx "$schema"; then
        return 1
    fi

    gsettings set "$schema" picture-uri "file://$WALLPAPER"

    if gsettings list-keys "$schema" | grep -Fqx picture-uri-dark; then
        gsettings set "$schema" picture-uri-dark "file://$WALLPAPER"
    fi
    if gsettings list-keys "$schema" | grep -Fqx picture-options; then
        gsettings set "$schema" picture-options zoom
    fi
}

set_mate_wallpaper() {
    local schema="org.mate.background"

    if ! command -v gsettings >/dev/null 2>&1 || \
       ! gsettings list-schemas | grep -Fqx "$schema"; then
        return 1
    fi

    gsettings set "$schema" picture-filename "$WALLPAPER"
    gsettings set "$schema" picture-options zoom
}

set_xfce_wallpaper() {
    local property
    local properties
    local changed=false

    command -v xfconf-query >/dev/null 2>&1 || return 1
    properties="$(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep '/last-image$' || true)"
    [[ -n "$properties" ]] || return 1

    while IFS= read -r property; do
        if xfconf-query -c xfce4-desktop -p "$property" -s "$WALLPAPER"; then
            changed=true
        fi
    done <<< "$properties"

    [[ "$changed" == true ]]
}

case "$DESKTOP_NAME" in
    *KDE*|*Plasma*)
        set_plasma_wallpaper && mark_complete
        ;;
    *Cinnamon*)
        set_gsettings_uri org.cinnamon.desktop.background && mark_complete
        ;;
    *MATE*)
        set_mate_wallpaper && mark_complete
        ;;
    *GNOME*|*Unity*|*Budgie*|*Pantheon*)
        set_gsettings_uri org.gnome.desktop.background && mark_complete
        ;;
    *XFCE*|*Xfce*)
        set_xfce_wallpaper && mark_complete
        ;;
    *LXQt*)
        command -v pcmanfm-qt >/dev/null 2>&1 && \
            pcmanfm-qt --set-wallpaper="$WALLPAPER" --wallpaper-mode=fit && \
            mark_complete
        ;;
    *LXDE*)
        command -v pcmanfm >/dev/null 2>&1 && \
            pcmanfm --set-wallpaper="$WALLPAPER" --wallpaper-mode=fit && \
            mark_complete
        ;;
esac

exit 0
EOF
chmod 755 /usr/local/bin/set-default-desktop-wallpaper

cat <<'EOF' > /etc/xdg/autostart/set-default-desktop-wallpaper.desktop
[Desktop Entry]
Type=Application
Name=Set Default Desktop Wallpaper
Exec=/usr/local/bin/set-default-desktop-wallpaper
X-KDE-autostart-after=panel
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF

# Remove files created by older versions of this installer for its custom
# SDDM theme. SDDM may remain installed as a KDE recommendation, but LightDM
# is the selected display manager.
rm -f /etc/sddm.conf.d/10-solids-group.conf \
      /usr/share/sddm/themes/solids-group/Main.qml \
      /usr/share/sddm/themes/solids-group/metadata.desktop
rmdir /usr/share/sddm/themes/solids-group 2>/dev/null || true

# Configure LightDM's packaged GTK greeter. The login panel is kept left of
# center so that it does not cover the centered logo in the group wallpaper.
show_progress 55 "Configure the LightDM login screen"
install -d -m755 /etc/lightdm/lightdm.conf.d \
                  /etc/lightdm/lightdm-gtk-greeter.conf.d

cat <<'EOF' > /etc/lightdm/lightdm.conf.d/50-solids-group.conf
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=plasma
allow-guest=false
EOF

cat <<'EOF' > /etc/lightdm/lightdm-gtk-greeter.conf.d/50-solids-group.conf
[greeter]
background=/usr/share/backgrounds/solidsgroup.png
user-background=false
position=15% 50%
keyboard=
a11y-states=-keyboard
EOF

# Install standard software
show_progress 62 "Install standard software and development tools"
"${APT_GET[@]}" install \
    emacs \
    mpich \
    python-is-python3 \
    git \
    libeigen3-dev \
    libpng-dev \
    libtclap-dev \
    libmuparser-dev \
    openssh-server \
    meld \
    python3-pip \
    texlive-latex-extra \
    texlive-fonts-extra \
    texlive-latex-base \
    texlive-publishers \
    texlive-science \
    snapd \
    ufw

# add everything needed to run with clang
show_progress 78 "Install the Clang toolchain"
"${APT_GET[@]}" install clang clangd libstdc++-14-dev libgfortran-14-dev

show_progress 84 "Start Snap support"
systemctl enable --now snapd.socket
timeout 300 snap wait system seed.loaded || true

install_snap() {
    local snap_name="$1"

    if snap list "$snap_name" >/dev/null 2>&1; then
        echo "Snap already installed: $snap_name"
        return 0
    fi

    for attempt in 1 2 3; do
        if snap install "$snap_name"; then
            return 0
        fi
        echo "Snap install failed for $snap_name (attempt $attempt of 3); retrying."
        sleep $((attempt * 10))
    done

    return 1
}

show_progress 88 "Install Slack"
install_snap slack
show_progress 93 "Install Overleaf"
install_snap overleaf

# Activate remote SSH login
show_progress 97 "Configure remote SSH access"
ufw allow OpenSSH

# Remove packages that are no longer needed only after the full installation
# has completed successfully.
show_progress 99 "Remove unneeded packages"
"${APT_GET[@]}" autoremove

show_progress 100 "Configuration complete"
