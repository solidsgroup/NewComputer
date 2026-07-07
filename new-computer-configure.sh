#!/bin/bash

#
# This is a Solids Group script to do routine update and setup of new computers.
# For best results, run using account of primary user.
# This script is stored in the "Web" folder on Google Drive.
#

# basic upgrade and update
apt -y update
apt -y upgrade

# Install lightdm-settings
# apt install lightdm-settings

# Ubuntu MATE 
# Choose LIGHTDM option. This is the only one that requires a dialog option
apt install -y ubuntu-mate-desktop ubuntu-mate-core compiz compiz-mate compizconfig-settings-manager

# KDE Plasma
apt install -y kde-plasma-desktop
apt remove -y magnus
apt remove -y plymouth-theme-ubuntu-mate-logo

# Jetbrains font
apt install -y  fonts-jetbrains-mono elpa-ligature


# Get a copy of the solids group wallpaper and set as background for now
cp wallpaper/solidsgroup.png /opt/wallpaper.png
cp wallpaper/solidsgroup.png /usr/share/backgrounds/solidsgroup.png
gsettings set org.gnome.desktop.background picture-uri file:////usr/share/backgrounds/solidsgroup.png

# Standard update/upgrade
apt -y update
apt -y upgrade
apt -y autoremove

# Install standard software (be sure to choose LIGHTDM as the login manager)
apt install -y emacs  mpich python-is-python3 git libeigen3-dev libpng-dev libtclap-dev libmuparser-dev openssh-server meld python3-pip texlive-latex-extra texlive-fonts-extra texlive-latex-base texlive-publishers texlive-science

# add everything needed to run with clang
apt install -y clang clangd libstdc++-14-dev libgfortran-14-dev

snap install slack overleaf

# Activate remote SSH login
ufw allow ssh


# Set the background for lightdm
#sed -i 's/warty-final-ubuntu.png/solidsgroup.png/g' /etc/lightdm/unity-greeter.conf

# gsettings set org.mate.background picture-filename /usr/share/backgrounds/solidsgroup.png
# Install standard software (be sure to choose LIGHTDM as the login manager)        

#lightdm-settings

cp /opt/wallpaper.png /usr/share/backgrounds/ubuntu-mate-common/Green-Wall-Logo.png
cp /opt/wallpaper.png /usr/share/backgrounds/ubuntu-mate-noble/numbat_wallpaper_green_3480x2160.jpg

# remove that weird un logo that seems to show up in the mate panel
rm /usr/share/icons/Yaru/scalable/status/un.svg


#
# When running mate with compiz, something prevents mate panel from running and
# caja from managing the desktop. This just triggers a restart on login which usually
# fixes the issue.
#

AUTOSTART_FILE="/etc/xdg/autostart/restart-mate-panel-caja.desktop"

# Create the .desktop file
cat <<EOF > "$AUTOSTART_FILE"
[Desktop Entry]
Type=Application
Name=Restart MATE Panel and Caja
Exec=bash -c "sleep 3 && pkill mate-panel && pkill caja"
OnlyShowIn=MATE;
X-GNOME-Autostart-enabled=true
EOF

# Set correct permissions
chmod 644 "$AUTOSTART_FILE"

echo "System-wide autostart entry created at $AUTOSTART_FILE"
