# New Computer Configuration

This repository contains an unattended installer for Ubuntu 24.04 LTS and
Ubuntu 26.04 LTS. It installs the complete KDE desktop, selects SDDM as the
login manager, installs the standard software used by the group, and
configures the supplied wallpapers.

- SDDM login background: `wallpaper/solidsgroup.png`
- Desktop background: `wallpaper/cubes.png`

The desktop wallpaper is applied once per user and desktop environment. A
user can change it afterward without the installer resetting it at every
login.

## Requirements

- Ubuntu 24.04 LTS or Ubuntu 26.04 LTS
- Internet access
- An account with `sudo` access
- The complete repository, including the `wallpaper` directory

The script can be started from any directory because it locates its assets
relative to its own path.

## Run in the terminal

From this repository, run:

```bash
sudo ./new-computer-configure.sh
```

Enter the `sudo` password when requested. After authentication, the installer
does not require further input. The terminal remains attached so its progress
is visible.

The script prints a 40-character overall progress bar at each major phase.
The percentage tracks completed phases rather than package download bytes;
detailed APT and Snap output remains visible and is written to the log.

## Run detached

To start the installer and immediately return to the terminal, run this from
the repository:

```bash
sudo systemd-run \
  --unit=new-computer-configure \
  --collect \
  "$(pwd)/new-computer-configure.sh"
```

The installation continues as a system service and survives closing the
terminal or logging out.

Follow its progress with either command:

```bash
sudo tail -f /var/log/new-computer-configure.log
```

```bash
sudo journalctl -fu new-computer-configure.service
```

While the detached installer is running, its service status is available with:

```bash
systemctl status new-computer-configure.service
```

Because the transient service uses `--collect`, it may disappear from
`systemctl status` after completion. The persistent installer log remains
available at:

```text
/var/log/new-computer-configure.log
```

## Completion and errors

The final log message reports either successful completion or the approximate
line where the installer failed. The installer automatically:

- answers package-manager prompts noninteractively;
- retains existing locally modified package configuration files;
- waits for temporary APT locks and retries network downloads;
- skips Snaps that are already installed;
- retries failed Snap installations; and
- prevents two copies of the installer from running simultaneously.

If a required step fails, the installer stops instead of continuing with a
partially configured system. Correct the reported problem and run the same
command again; package installation and configuration steps are safe to
repeat.

### Repair an SDDM/LightDM mismatch

An earlier version of this installer could enable SDDM while leaving LightDM
in `/etc/X11/default-display-manager`. If SDDM consequently fails before the
login screen appears, open a text console with `Ctrl`+`Alt`+`F3`, sign in, and
run:

```bash
printf '/usr/bin/sddm\n' | sudo tee /etc/X11/default-display-manager >/dev/null
echo 'shared shared/default-x-display-manager select sddm' | sudo debconf-set-selections
sudo systemctl enable --force sddm.service
sudo systemctl reset-failed sddm.service
sudo systemctl restart sddm.service
```

## After installation

The installer does not reboot automatically. After it reports successful
completion, reboot to start SDDM and KDE Plasma:

```bash
sudo reboot
```

The `cubes.png` desktop wallpaper is applied when each user first logs into a
supported desktop session. Plasma, GNOME-family desktops, Cinnamon, MATE,
Xfce, LXQt, and LXDE are handled by the wallpaper initializer.
