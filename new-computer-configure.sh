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

exec 9>/run/lock/new-computer-configure.lock
if ! flock -n 9; then
    echo "Another copy of this installer is already running."
    exit 1
fi

touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

show_progress() {
    local percent="$1"
    local message="$2"
    local width=40
    local filled
    local empty
    local completed_bar
    local remaining_bar

    if (( percent < 0 || percent > 100 )); then
        echo "Invalid progress percentage: $percent" >&2
        return 1
    fi

    filled=$((percent * width / 100))
    empty=$((width - filled))
    printf -v completed_bar '%*s' "$filled" ''
    printf -v remaining_bar '%*s' "$empty" ''
    completed_bar="${completed_bar// /#}"
    remaining_bar="${remaining_bar// /-}"
    PROGRESS_PERCENT="$percent"

    printf '\n[%s%s] %3d%% %s\n' \
        "$completed_bar" "$remaining_bar" "$percent" "$message"
}

trap 'FAILED_LINE=$LINENO' ERR
finish() {
    local exit_status=$?

    if [[ $exit_status -eq 0 ]]; then
        echo "Configuration completed successfully at $(date --iso-8601=seconds)."
        echo "A reboot is recommended. Log: $LOG_FILE"
    else
        echo "Configuration failed near line $FAILED_LINE with status $exit_status."
        echo "Installer stopped at approximately $PROGRESS_PERCENT%."
        echo "Review the log at $LOG_FILE"
    fi
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

. /etc/os-release
case "${VERSION_ID:-}" in
    24.04)
        SDDM_QML_PACKAGES=(
            qml-module-qtquick-controls2
            qml-module-qtquick-layouts
        )
        ;;
    26.04)
        SDDM_QML_PACKAGES=(
            qml6-module-qtquick-controls
            qml6-module-qtquick-layouts
        )
        ;;
    *)
        echo "Unsupported Ubuntu release: ${VERSION_ID:-unknown}. Expected 24.04 or 26.04."
        exit 1
        ;;
esac

echo "Starting unattended configuration for Ubuntu $VERSION_ID."
echo "Progress is being logged to $LOG_FILE"
show_progress 0 "Starting configuration"

# basic upgrade and update
show_progress 5 "Refreshing Ubuntu package metadata"
"${APT_GET[@]}" update
show_progress 12 "Upgrading installed Ubuntu packages"
"${APT_GET[@]}" upgrade

# kde-full and several supporting packages are in Universe. Enable it when a
# minimal Ubuntu installation does not already provide it.
show_progress 18 "Checking required Ubuntu repositories"
if ! apt-cache show kde-full >/dev/null 2>&1; then
    "${APT_GET[@]}" install software-properties-common
    add-apt-repository -y universe
    "${APT_GET[@]}" update
fi

# Install the complete KDE desktop and use KDE's SDDM login manager.
# Preseeding the display-manager choice keeps this install non-interactive.
# Ubuntu's display-manager package scripts preserve an existing selection, so
# also update the authoritative file explicitly after installing SDDM. This
# keeps that file and systemd's display-manager.service link in agreement.
show_progress 22 "Installing KDE Plasma and SDDM"
echo "shared shared/default-x-display-manager select sddm" | debconf-set-selections
"${APT_GET[@]}" install \
    kde-full \
    sddm \
    "${SDDM_QML_PACKAGES[@]}"
printf '%s\n' /usr/bin/sddm > /etc/X11/default-display-manager
echo "shared shared/default-x-display-manager select sddm" | debconf-set-selections
dpkg-reconfigure sddm
systemctl enable --force sddm.service

# Jetbrains font
show_progress 42 "Installing fonts"
"${APT_GET[@]}" install fonts-jetbrains-mono elpa-ligature


# Install the login and desktop wallpapers.
show_progress 47 "Installing desktop and login wallpapers"
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

# Use a custom SDDM theme with its login card on the left, leaving the logo in
# the center of the wallpaper unobstructed.
show_progress 55 "Configuring the SDDM login screen"
SDDM_THEME_DIR="/usr/share/sddm/themes/solids-group"
install -d -m755 "$SDDM_THEME_DIR" /etc/sddm.conf.d

cat <<'EOF' > "$SDDM_THEME_DIR/metadata.desktop"
[SddmGreeterTheme]
Name=Solids Group
Description=Solids Group login theme with a left-aligned login card
Author=Solids Group
License=CC-BY-SA
Type=sddm-theme
Version=1.0
MainScript=Main.qml
Theme-Id=solids-group
Theme-API=2.0
EOF

cat <<'EOF' > "$SDDM_THEME_DIR/Main.qml"
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Rectangle {
    id: root
    width: 1920
    height: 1080
    color: "#080a0c"

    function logIn() {
        message.text = "Signing in..."
        sddm.login(username.text, password.text, session.currentIndex)
    }

    Image {
        anchors.fill: parent
        source: "file:///usr/share/backgrounds/solidsgroup.png"
        fillMode: Image.PreserveAspectCrop
        horizontalAlignment: Image.AlignHCenter
        verticalAlignment: Image.AlignVCenter
        asynchronous: true
        cache: true
    }

    Rectangle {
        id: loginCard
        width: Math.min(390, root.width * 0.30)
        height: loginLayout.implicitHeight + 64
        anchors.left: parent.left
        anchors.leftMargin: Math.max(24, root.width * 0.04)
        anchors.verticalCenter: parent.verticalCenter
        radius: 12
        color: "#d9161a1e"
        border.width: 1
        border.color: "#553b83b6"

        ColumnLayout {
            id: loginLayout
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Math.min(32, loginCard.width * 0.08)
            spacing: 14

            Label {
                text: "Welcome"
                color: "white"
                font.pixelSize: 28
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }

            Label {
                text: Qt.formatDateTime(new Date(), "dddd, MMMM d")
                color: "#b8c1cc"
                font.pixelSize: 14
                Layout.fillWidth: true
            }

            Item { height: 4 }

            TextField {
                id: username
                placeholderText: "Username"
                text: userModel.lastUser
                selectByMouse: true
                Layout.fillWidth: true
                onAccepted: password.forceActiveFocus()
            }

            TextField {
                id: password
                placeholderText: "Password"
                echoMode: TextInput.Password
                selectByMouse: true
                Layout.fillWidth: true
                onAccepted: root.logIn()
            }

            ComboBox {
                id: session
                model: sessionModel
                textRole: "name"
                currentIndex: sessionModel.lastIndex
                Layout.fillWidth: true
            }

            Button {
                text: "Sign In"
                highlighted: true
                Layout.fillWidth: true
                onClicked: root.logIn()
            }

            Label {
                id: message
                text: ""
                color: "#ff8a80"
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 12

                Button {
                    text: "Restart"
                    flat: true
                    visible: sddm.canReboot
                    onClicked: sddm.reboot()
                }

                Button {
                    text: "Shut Down"
                    flat: true
                    visible: sddm.canPowerOff
                    onClicked: sddm.powerOff()
                }
            }
        }
    }

    Connections {
        target: sddm

        function onLoginFailed() {
            message.text = "Login failed"
            password.text = ""
            password.forceActiveFocus()
        }
    }

    Component.onCompleted: {
        if (username.text.length > 0)
            password.forceActiveFocus()
        else
            username.forceActiveFocus()
    }
}
EOF

cat <<'EOF' > /etc/sddm.conf.d/10-solids-group.conf
[General]
InputMethod=

[Theme]
Current=solids-group
EOF

# Install standard software
show_progress 62 "Installing standard software and development tools"
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
show_progress 78 "Installing the Clang toolchain"
"${APT_GET[@]}" install clang clangd libstdc++-14-dev libgfortran-14-dev

show_progress 84 "Starting Snap support"
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

show_progress 88 "Installing Slack"
install_snap slack
show_progress 93 "Installing Overleaf"
install_snap overleaf

# Activate remote SSH login
show_progress 97 "Configuring remote SSH access"
ufw allow OpenSSH

# Remove packages that are no longer needed only after the full installation
# has completed successfully.
show_progress 99 "Removing unneeded packages"
"${APT_GET[@]}" autoremove

show_progress 100 "Configuration complete"
