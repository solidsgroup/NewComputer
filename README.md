# New Computer Configuration

Sets up a Solids Group workstation on **Ubuntu 24.04 or 26.04 LTS (amd64/x86-64)** with KDE, research and development tools, Slack with math rendering, and ISU VPN support. Requires internet access, `curl`, and `sudo` privileges.

## Install

**Regular install** — keep the terminal open; enter your sudo password if prompted. Press **L** to toggle the live log or **Ctrl+C** to cancel.

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw+json' 'https://api.github.com/repos/solidsgroup/NewComputer/contents/install.sh?ref=master' | sudo bash
```

**Unattended install** — starts a background service and continues after closing the terminal or logging out. Only the initial sudo authentication may require input.

```bash
sudo systemd-run --unit=new-computer-configure --collect /bin/bash -o pipefail -c "curl -fsSL -H 'Accept: application/vnd.github.raw+json' 'https://api.github.com/repos/solidsgroup/NewComputer/contents/install.sh?ref=master' | bash"
```

Neither command requires a Git clone. Both run without installation prompts and stop on errors. Reboot after successful completion; the installer does not reboot automatically.

## Progress and troubleshooting

- **Background progress:** `sudo journalctl -fu new-computer-configure.service`
- **Full installer log:** `sudo tail -f /var/log/new-computer-configure.log`
- **Background status:** `systemctl status new-computer-configure.service` (the service is removed after completion).
- **Local checkout:** `sudo ./new-computer-configure.sh`
- **Failure or cancellation:** check the log, resolve the problem, and rerun. Completed changes are not rolled back; repeat runs reapply setup and skip existing large downloads.

## What gets installed

- **Desktop:** KDE Plasma, LightDM/Slick Greeter, fonts, and group wallpapers. Defaults include a dark theme, a 30-minute screen lock, and no automatic display sleep, suspend, or lid-close action.
- **Applications:** Chrome, Slack with math-with-slack, Emacs, Evince, Inkscape with TexText, Meld, and FFmpeg.
- **Research and development:** Git, Python/pip, Node.js/npm, Clang/clangd, MPICH, development libraries, TeX Live (including `texlive-bibtex-extra`), `latexmk`, and VisIt 3.5/3.4.
- **Networking:** OpenSSH, UFW with SSH allowed, and OpenConnect/NetworkManager configured for ISU.

## After installation

- **ISU VPN:** click **Connect** beside **ISU** in KDE, or run `isu-vpn`. Complete browser sign-in and MFA. Uses `vpn.iastate.edu`, the **Primary** group, and split routing based on [official ISU instructions](https://iastate.service-now.com/it?id=kb_article&sysparm_article=KB0011105), adapted for OpenConnect. VPN login is not part of the unattended installation.
- **TexText:** restart Inkscape, then open **Extensions → Text → TexText**.
  If an account already has a manually installed TexText copy, the installer
  disables that duplicate so it cannot conflict with Ubuntu's package. The
  old copy is retained under `~/.config/inkscape/disabled-extensions`, and its
  `default_packages.tex` remains active at the original configured path.
- **Slack math:** restart Slack; use `$ ... $` or `$$ ... $$`. Rendering requires the patch on each viewer's desktop. After a Slack update, close Slack and run `sudo /usr/local/sbin/install-slack-math` to reapply it.
- **VisIt:** use `visit` or `visit3.5` for 3.5.0, and `visit3.4` for 3.4.2.

## CI

[![Installer CI](https://github.com/solidsgroup/NewComputer/actions/workflows/ci.yml/badge.svg)](https://github.com/solidsgroup/NewComputer/actions/workflows/ci.yml)

CI checks both Ubuntu versions on every push and monthly: installer flow, package dependency resolution, external download URLs, terminal controls, and helper tests. Desktop rendering and authenticated VPN access require manual verification.

## Potentially fragile installations

| Package or integration | Dependency that can break |
| --- | --- |
| Google Chrome | Direct `.deb` download from Google's website. |
| Slack desktop | Version-specific `.deb` URL on Slack's download server. |
| math-with-slack | Pinned GitHub patcher and MathJax archive from npm; Slack updates can overwrite or invalidate the patch. |
| VisIt 3.5/3.4 | Large, version-specific GitHub release archives with pinned checksums; Ubuntu 24 binaries are also used on Ubuntu 26.04. |
| TexText compatibility fix | Ubuntu 26.04 patch depends on TexText's Python source layout; package updates can replace it. |

The bootstrap also depends on GitHub's API, commit feed, and raw-file downloads. Most other software comes from Ubuntu's APT repositories.
