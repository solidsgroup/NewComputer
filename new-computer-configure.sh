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
GOOGLE_CHROME_DEB_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
LOG_FILE="/var/log/new-computer-configure.log"
FAILED_LINE="unknown"
PROGRESS_PERCENT=0
UI_CURRENT_STEP=-1
UI_STATE="running"
CANCELLED_SIGNAL=""

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
    "Configure the Slick Greeter login screen"
    "Install standard software and development tools"
    "Ensure Google Chrome is installed"
    "Install the Clang toolchain"
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

if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
    echo "Unsupported architecture: Google Chrome for Linux requires amd64/x86-64."
    exit 1
fi

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
        elif [[ "$UI_STATE" == "cancelled" && $index -eq $UI_CURRENT_STEP ]]; then
            printf '  %s■%s  %s%s%s %s(cancelled)%s\n' \
                "$orange" "$reset" "$bold" "$label" "$reset" "$dim" "$reset" >&3
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
        cancelled)
            printf '  %s■ Setup cancelled%s  ·  Completed work was not undone\n' \
                "$orange" "$reset" >&3
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

cancel_installation() {
    local signal="$1"
    local exit_status

    CANCELLED_SIGNAL="$signal"
    UI_STATE="cancelled"

    case "$signal" in
        INT)
            exit_status=130
            ;;
        TERM)
            exit_status=143
            ;;
        *)
            exit_status=1
            ;;
    esac

    exit "$exit_status"
}

trap 'FAILED_LINE=$LINENO' ERR
finish() {
    local exit_status=$?

    trap - ERR INT TERM EXIT

    if [[ -n "$CANCELLED_SIGNAL" ]]; then
        echo "Configuration cancelled by SIG$CANCELLED_SIGNAL."
        echo "Installer stopped at approximately $PROGRESS_PERCENT%."
        echo "Completed changes were not rolled back. Log: $LOG_FILE"
        UI_STATE="cancelled"
        render_ui
        if [[ "$UI_IS_TTY" != true ]]; then
            if (( UI_CURRENT_STEP >= 0 && UI_CURRENT_STEP < ${#UI_STEPS[@]} )); then
                printf '[%3d%%] ■ Cancelled: %s\n' \
                    "$PROGRESS_PERCENT" "${UI_STEPS[$UI_CURRENT_STEP]}" >&3
            fi
            printf 'Configuration cancelled by SIG%s at approximately %s%%. Log: %s\n' \
                "$CANCELLED_SIGNAL" "$PROGRESS_PERCENT" "$LOG_FILE" >&3
        fi
    elif [[ $exit_status -eq 0 ]]; then
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
trap 'cancel_installation INT' INT
trap 'cancel_installation TERM' TERM

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

# Install the complete KDE desktop and use LightDM's standard Slick Greeter.
# Preseeding the display-manager choice keeps this install non-interactive.
# Ubuntu's display-manager package scripts preserve an existing selection, so
# also update the authoritative file explicitly after installing LightDM. This
# keeps that file and systemd's display-manager.service link in agreement.
show_progress 22 "Install KDE Plasma and LightDM"
echo "shared shared/default-x-display-manager select lightdm" | debconf-set-selections
"${APT_GET[@]}" install \
    kde-full \
    lightdm \
    slick-greeter \
    breeze-gtk-theme \
    breeze-icon-theme
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

# Supply a system-wide Plasma lock-screen default. The per-user initializer
# below also applies it once so existing accounts with an older value receive
# the group default without preventing later user customization.
cat <<'EOF' > /etc/xdg/kscreenlockerrc
[Greeter]
WallpaperPlugin=org.kde.image

[Greeter][Wallpaper][org.kde.image][General]
Image=/usr/share/backgrounds/cubes.png
PreviewImage=/usr/share/backgrounds/cubes.png
EOF

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
LOCK_MARKER="$HOME/.config/.cubes-plasma-lock-screen-set"

mark_complete() {
    mkdir -p "$(dirname -- "$MARKER")"
    touch "$MARKER"
}

mark_lock_complete() {
    mkdir -p "$(dirname -- "$LOCK_MARKER")"
    touch "$LOCK_MARKER"
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

set_plasma_lock_screen() {
    local kwriteconfig_command

    for kwriteconfig_command in kwriteconfig6 kwriteconfig5; do
        if command -v "$kwriteconfig_command" >/dev/null 2>&1 && \
           "$kwriteconfig_command" --file kscreenlockerrc \
               --group Greeter --key WallpaperPlugin org.kde.image && \
           "$kwriteconfig_command" --file kscreenlockerrc \
               --group Greeter --group Wallpaper --group org.kde.image \
               --group General --key Image "$WALLPAPER" && \
           "$kwriteconfig_command" --file kscreenlockerrc \
               --group Greeter --group Wallpaper --group org.kde.image \
               --group General --key PreviewImage "$WALLPAPER"; then
            return 0
        fi
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

# The lock screen has a separate setting from the Plasma desktop wallpaper.
# Apply it once even when an earlier installer run already set the desktop.
case "$DESKTOP_NAME" in
    *KDE*|*Plasma*)
        if [[ ! -e "$LOCK_MARKER" ]] && set_plasma_lock_screen; then
            mark_lock_complete
        fi
        ;;
esac

[[ -e "$MARKER" ]] && exit 0

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

# Configure LightDM's packaged Slick Greeter. Use a late-loading filename so
# settings left by another desktop environment cannot override this choice.
show_progress 55 "Configure the Slick Greeter login screen"
install -d -m755 /etc/lightdm/lightdm.conf.d
rm -f /etc/lightdm/lightdm.conf.d/50-solids-group.conf \
      /etc/lightdm/lightdm-gtk-greeter.conf.d/50-solids-group.conf

cat <<'EOF' > /etc/lightdm/lightdm.conf.d/99-solids-group.conf
[Seat:*]
greeter-session=slick-greeter
user-session=plasma
allow-guest=false
greeter-allow-guest=false
greeter-show-manual-login=true
greeter-show-remote-login=false
EOF

cat <<'EOF' > /etc/lightdm/slick-greeter.conf
[Greeter]
background=/usr/share/backgrounds/solidsgroup.png
background-color=#10151c
draw-user-backgrounds=false
draw-grid=false
theme-name=Breeze-Dark
icon-theme-name=breeze
font-name=Ubuntu 11
show-hostname=true
show-keyboard=true
show-a11y=true
show-power=true
show-clock=true
show-quit=true
onscreen-keyboard=false
enable-hidpi=auto
only_on_monitor=-1
EOF

# Install standard software
show_progress 62 "Install standard software and development tools"
"${APT_GET[@]}" install \
    emacs \
    mpich \
    python-is-python3 \
    git \
    ca-certificates \
    curl \
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
    ufw

install_google_chrome() {
    local chrome_deb
    local package_architecture=""
    local package_name=""
    local package_version=""
    local status=0

    if dpkg-query -W -f='${db:Status-Status}\n' google-chrome-stable \
        2>/dev/null | grep -Fxq installed; then
        echo "Google Chrome is already installed; skipping the package download."
        return 0
    fi

    if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
        echo "Google Chrome is only available from Google for amd64 systems." >&2
        return 1
    fi

    chrome_deb="$(mktemp --tmpdir=/tmp --suffix=.deb google-chrome-stable.XXXXXX)"
    curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 5 \
        --retry-delay 2 \
        "$GOOGLE_CHROME_DEB_URL" \
        --output "$chrome_deb" || status=$?

    if (( status == 0 )); then
        package_name="$(dpkg-deb --field "$chrome_deb" Package)" || status=$?
        package_version="$(dpkg-deb --field "$chrome_deb" Version)" || status=$?
        package_architecture="$(dpkg-deb --field "$chrome_deb" Architecture)" || status=$?
    fi

    if (( status == 0 )) && \
       { [[ "$package_name" != "google-chrome-stable" ]] || \
         [[ "$package_architecture" != "amd64" ]]; }; then
        echo "Unexpected package downloaded from Google Chrome URL: " \
             "$package_name $package_architecture" >&2
        status=1
    fi

    if (( status == 0 )); then
        echo "Installing Google Chrome $package_version."
        "${APT_GET[@]}" install "$chrome_deb" || status=$?
    fi

    rm -f -- "$chrome_deb"
    return "$status"
}

show_progress 75 "Ensure Google Chrome is installed"
install_google_chrome

# add everything needed to run with clang
show_progress 78 "Install the Clang toolchain"
"${APT_GET[@]}" install clang clangd libstdc++-14-dev libgfortran-14-dev

# Activate remote SSH login
show_progress 97 "Configure remote SSH access"
ufw allow OpenSSH

# Remove packages that are no longer needed only after the full installation
# has completed successfully.
show_progress 99 "Remove unneeded packages"
"${APT_GET[@]}" autoremove

show_progress 100 "Configuration complete"
