# New Computer Configuration

[![Installer CI](https://github.com/solidsgroup/NewComputer/actions/workflows/ci.yml/badge.svg)](https://github.com/solidsgroup/NewComputer/actions/workflows/ci.yml)

This repository contains an unattended installer for Ubuntu 24.04 LTS and
Ubuntu 26.04 LTS. It installs the complete KDE desktop, selects LightDM with
Slick Greeter as the login manager, installs the standard software used by the
group—including Google Chrome, Slack desktop, Node.js, and npm—and configures
the supplied wallpapers.

Inkscape includes the TexText extension through Ubuntu's `inkscape-textext`
package, along with its dependencies and the installer's TeX Live packages.
After installation, restart Inkscape and open **Extensions → Text → TexText** to
insert and re-edit LaTeX graphics.
On Ubuntu 26.04, the installer filters TexText's known `GLib.unix_signal_add_full`
deprecation warning before GTK loads, preserving other warnings and errors.
Rerun the installer if a TexText package update replaces the patched file.

The installer configures an `ISU` OpenConnect VPN connection on both Ubuntu
releases, using the server `vpn.iastate.edu` and **Primary** group from
[ISU's official VPN instructions (KB0011105)](https://iastate.service-now.com/it?id=kb_article&sysparm_article=KB0011105).
In KDE, click **Connect** beside **ISU** in the network panel. A session login
agent opens your usual browser and shows a short notification once the VPN is
connected. The agent starts automatically at login and handles only the ISU
OpenConnect profile; other connections retain their normal login dialogs. After
installing in an existing desktop session, log out and back in, or run
`isu-vpn-agent` to start it immediately. Browser sign-in times out after three
minutes; clicking Disconnect cancels a pending sign-in.

You can also open **ISU VPN** in the application menu or run `isu-vpn` in a
terminal without sudo. Complete the Sign On Dashboard login and MFA in your
browser. The login handler then activates the connection through NetworkManager; disconnect using the
network panel or `nmcli connection down ISU`.

ISU documents Cisco Secure Client; this installer adapts those settings for
OpenConnect. The generic `AnyConnect` user agent enables the gateway's browser
login flow, as verified against the live gateway. The login handler explicitly
selects Primary and avoids desktop-specific embedded-browser limitations. Login tokens
are handed to NetworkManager in memory, never put in command arguments or saved
to disk by the login handler. The installer never signs in or connects
automatically.
Server-provided routes and DNS are accepted, with default routes disabled so
non-ISU traffic keeps using the usual connection, as described by ISU.

Rerunning setup updates the existing `ISU` OpenConnect profile without changing
its UUID or other connections. It clears old authentication settings and cached
profile secrets. To configure just the VPN again: `sudo isu-vpn --configure`.
An authenticated session is required to verify campus access and DNS; CI checks
configuration and token handoff without university credentials.

If an incompatible Cisco package is already partially installed,
repair APT before running the installer:

```bash
sudo apt-get install openconnect network-manager-openconnect network-manager-openconnect-gnome cisco-secure-client-vpn-
```

The trailing `-` requests removal of the old Cisco VPN package.

On Ubuntu 26.04, Inkscape uses a launcher that disables global-menu forwarding
in KDE and selects X11/XWayland in KDE Wayland sessions. This keeps its menu
inside the application window and avoids the disappearing-menu issue. The
terminal command, application launcher, and New Window action use this helper;
other desktop sessions retain their normal backend. Restart Inkscape after
running the installer to apply the change.

LLNL VisIt is installed from its official precompiled Ubuntu 24 binary
distributions. The maintained 3.5 and 3.4 series are installed side by side:
`visit` and `visit3.5` launch VisIt 3.5.0, while `visit3.4` launches VisIt
3.4.2. The archives are verified against LLNL's published SHA-256 checksums,
and an already installed version is not downloaded again. FFmpeg is installed
for VisIt's movie-export workflow.

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

KDE defaults are applied to every existing human account and once at the first
Plasma login for future accounts. Plasma uses Breeze Dark, locks after 30
minutes of inactivity, and never turns off the display or automatically
suspends or shuts down on AC, battery, or low battery. Closing a laptop lid
also takes no action. The separate critical-battery action is deliberately
left intact, as are explicit power-button actions. Users can change these
defaults afterward.

Google Chrome Stable is downloaded directly from Google's official Linux
package URL during its first installation and installed noninteractively.
Later installer runs detect the installed package and skip that large
download; the normal APT upgrade phase handles available Chrome updates.

Node.js and npm are installed from Ubuntu's repositories. Slack is installed
from its official amd64 `.deb` package (initial version 4.52.155), with repeat
runs skipping the download when `slack-desktop` is already installed.

The installer applies [math-with-slack](https://github.com/thisiscam/math-with-slack)
from the successor fork linked by the original project, which does not support
Slack 4. The patcher and MathJax 3.1.0 downloads are pinned and checked with
SHA-256. Python's setuptools package supplies the patcher's compatibility
dependency on current Ubuntu releases. The Snap version of Slack cannot be
patched; use the installed `.deb` application if a Snap copy is also present.

Restart Slack after patching. Write `$ ... $` for inline math or `$$ ... $$`
for display math; only people with the patch installed see rendered equations.
Slack updates can overwrite the patch. Close Slack and reapply it with:

```bash
sudo /usr/local/sbin/install-slack-math
```

Then reopen Slack. Rerunning the full installer also reapplies the patch.
Future Slack releases may require an updated patcher.

## Requirements

- Ubuntu 24.04 LTS or Ubuntu 26.04 LTS
- An amd64/x86-64 computer, as required by Google Chrome for Linux
- Internet access
- An account with `sudo` access
- `curl` for the no-clone command below
- The complete repository, including the `kde`, `inkscape`, `visit`, `slack`, and `wallpaper`
  directories, for a local run

The script can be started from any directory because it locates its assets
relative to its own path.

## Run directly from GitHub

Copy and paste this one-liner. The bootstrap downloads the installer, its KDE
and VisIt helpers, the Slack math helper, and both wallpapers; it runs the
installer and removes its temporary files afterward. No Git clone or checkout
is required.

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
fresh package indexes, and the Google Chrome and Slack package URLs are checked
without installing the applications. Service and firewall operations are
recorded and verified rather than applied; generated configuration files, installed
wallpaper assets, and VisIt's multi-version launcher layout are created and
checked on the disposable runner. CI checks LLNL's real release URLs without
downloading the roughly 1.2 GB of binary archives.
Slack installation and patcher invocation are mocked in this smoke test;
it does not verify rendering inside a signed-in Slack session.

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
