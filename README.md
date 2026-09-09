# New Computer Configuration

[![Installer CI](https://github.com/solidsgroup/NewComputer/actions/workflows/ci.yml/badge.svg)](https://github.com/solidsgroup/NewComputer/actions/workflows/ci.yml)

This repository contains an unattended installer for Ubuntu 24.04 LTS and
Ubuntu 26.04 LTS. It installs the complete KDE desktop, selects LightDM with
Slick Greeter as the login manager, installs the standard software used by the
group—including Google Chrome—and configures the supplied wallpapers.

- LightDM login background: `wallpaper/solidsgroup.png`
- Desktop background: `wallpaper/cubes.png`
- Plasma lock-screen background: `wallpaper/cubes.png`

LightDM uses its packaged Slick Greeter with KDE's Breeze Dark styling rather
than a custom theme. Plasma is selected by default, and the greeter provides a
session chooser for selecting another installed desktop. The on-screen
keyboard is disabled by default.

The desktop wallpaper is applied once per user and desktop environment. A
user can change it afterward without the installer resetting it at every
login. The Plasma lock-screen wallpaper is likewise applied once per user and
can be changed afterward.

Google Chrome Stable is downloaded directly from Google's official Linux
package URL during its first installation and installed noninteractively.
Later installer runs detect the installed package and skip that large
download; the normal APT upgrade phase handles available Chrome updates.

## Requirements

- Ubuntu 24.04 LTS or Ubuntu 26.04 LTS
- An amd64/x86-64 computer, as required by Google Chrome for Linux
- Internet access
- An account with `sudo` access
- `curl` for the no-clone command below
- The complete repository, including the `wallpaper` directory, for a local run

The script can be started from any directory because it locates its assets
relative to its own path.

## Run directly from GitHub

Copy and paste this one-liner. The bootstrap downloads the installer and both
wallpapers, runs the installer, and removes its temporary files afterward. No
Git clone or checkout is required.

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw+json' 'https://api.github.com/repos/solidsgroup/NewComputer/contents/install.sh?ref=master' | sudo bash
```

This API-backed bootstrap request avoids the short cache delay that GitHub's
raw branch URLs can have immediately after a push. The bootstrap resolves the
current commit and downloads all remaining files from that exact revision, so
one run cannot mix files from different commits.

## Run from a local checkout

From this repository, run:

```bash
sudo ./new-computer-configure.sh
```

Enter the `sudo` password when requested. After authentication, the installer
does not require further input. The terminal remains attached so its progress
is visible.

The script opens a Solids Group-branded terminal checklist using the group's
blue and orange colors. Completed, active, pending, and failed phases remain
visible while the installer runs. The percentage marks the overall phase
position rather than package download bytes.

Verbose APT and configuration output is hidden from the interface and
written to `/var/log/new-computer-configure.log`. If the installer stops, the
failed checklist item and the relevant script line are shown alongside the log
location. Set the standard `NO_COLOR` environment variable if you want the
same interface without color:

```bash
sudo NO_COLOR=1 ./new-computer-configure.sh
```

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

Follow its compact progress checklist with:

```bash
sudo journalctl -fu new-computer-configure.service
```

Follow the detailed command output with:

```bash
sudo tail -f /var/log/new-computer-configure.log
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

## Continuous integration

GitHub Actions smoke-tests the complete installer flow on native Ubuntu 24.04
and Ubuntu 26.04 runners after every push and at 09:23 UTC on the first day of
each month. APT resolves every requested operation in simulation mode against
fresh package indexes, and the Google Chrome package URL is checked without
installing the application. Service and firewall operations are recorded and
verified rather than applied; generated configuration files and installed
wallpaper assets are created and checked on the disposable runner.

## Completion and errors

The final log message reports either successful completion or the approximate
line where the installer failed. The installer automatically:

- answers package-manager prompts noninteractively;
- retains existing locally modified package configuration files;
- waits for temporary APT locks and retries network downloads;
- prevents two copies of the installer from running simultaneously.

If a required step fails, the installer stops instead of continuing with a
partially configured system. Correct the reported problem and run the same
command again; package installation and configuration steps are safe to
repeat.

Pressing `Ctrl+C` cancels the run with status 130. The active checklist item is
marked as cancelled, later items remain pending, and completed changes are not
rolled back. Running the installer again safely resumes its idempotent setup
steps.

## After installation

The installer does not reboot automatically. After it reports successful
completion, reboot to start LightDM and KDE Plasma:

```bash
sudo reboot
```

The `cubes.png` desktop wallpaper is applied when each user first logs into a
supported desktop session. Plasma, GNOME-family desktops, Cinnamon, MATE,
Xfce, LXQt, and LXDE are handled by the wallpaper initializer.
