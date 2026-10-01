# Solids Group Shared Drive

The installer adds rclone, FUSE 3, a KDE autostart entry, and a per-user service.
Every user mounts the same Shared Drive (`0ABOlbDUzr0nyUk9PVA`) at `~/gdrive`
using their own Google account. Changes use that account's permissions and identity.
Users can be logged in simultaneously. Linux usernames determine the folders
created in the drive; these folders are visible to other drive members.

## Administrator setup (once)

Rclone's public Google OAuth client is being retired in 2026. Create your own:

1. In [Google Cloud Console](https://console.cloud.google.com/), create a project
   under the `solids.group` organization and enable **Google Drive API**.
2. In **Google Auth Platform**, configure branding/contact emails and select an
   **Internal** audience. Add `https://www.googleapis.com/auth/drive` under
   **Data Access**.
3. Under **Clients**, create a **Desktop app** client and download its JSON.
4. On each workstation, after installing, run:

   ```bash
   sudo solids-drive --install-client /path/to/downloaded-client.json
   ```

This installs only the application identity in `/etc/solids-drive/client.json`.
It grants no Drive access by itself. Native desktop client credentials must be
readable by the users of the application; personal Google refresh tokens remain
private in each user's `~/.config/solids-drive/rclone.conf` (directory 0700,
file 0600). Do not commit either JSON downloads or user tokens to this repository.
Installer reruns preserve these files. Provision the client JSON separately on
new workstations; unattended installation does not authenticate anybody.

If Workspace blocks the application, allow this OAuth client through the admin
API controls. Members need write access to the Shared Drive to create folders.
See [rclone's Google setup](https://rclone.org/drive/#making-your-own-client-id).

## User experience

Run `solids-drive`, select it in the application menu, or log into KDE. On first
use a browser requests authorization; choose your `solids.group` account.
Subsequent logins reuse the refresh token. Cancelled/unfinished sign-in is offered
again on the next login (or when running `solids-drive`). Simultaneous first-time
sign-ins wait their turn because rclone uses a fixed localhost callback port.

The drive appears at `~/gdrive` with a **Solids Group** Dolphin bookmark. A folder
named after your Linux username is created after mounting. Google Docs/Sheets
appear as HTML links that open in the browser. A pre-existing nonempty `~/gdrive`
or a symlink is left untouched; move it aside before connecting.

Useful commands:

```bash
solids-drive --reauth                 # choose another account or renew authorization
systemctl --user stop solids-drive    # stop this user's mount
journalctl --user -u solids-drive     # status and retry messages (no tokens)
```

Network/permission/quota failures retry without discarding credentials. Revoked
refresh tokens trigger another browser login. Workspace policy may also require
reauthorization; permanent sign-in cannot be guaranteed.

The mount starts with KDE and stops with the graphical session. Each user has a
separate private cache (5 GiB target; open/pending files can exceed it). This is
streamed storage, not a complete offline copy. Allow uploads to finish before
logging out; pending cached writes are retained for the next mount. Avoid editing
the same ordinary file simultaneously from different computers/accounts: rclone
does not provide collaborative editing or cross-client file locking.

## Validation

CI tests credential reuse, cancellation, network versus authorization failures,
user isolation, folder creation, mount refusal, and a real rclone mount against
temporary local storage. Live Google authorization requires the organization's
OAuth client and a member's browser sign-in.
