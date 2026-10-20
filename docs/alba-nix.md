# alba-nix: provisioning and migration runbook

The boat-services VM. Design context: `CONTEXT.md` (vocabulary) and
`docs/adr/0001`–`0004` (why it's shaped this way). This file is the
do-it order of operations. Phase 1 scope: sabnzbd + sonarr + radarr +
whisparr + stash, SMB libraries from vault, self-monitoring, restic to
B2. qbittorrent + AirVPN is phase 2; absorbing the docker VM is phase 3
(3a = Signal K, below).

## 1. One-time preparation (appliances, web consoles)

**Proxmox** (before install):

- Shrink the docker VM 8 GB → 6 GB (Hardware → Memory; takes effect on
  its next restart, pick a calm moment).
- Create the VM: 4 vCPU (type `host`), 5 GB RAM with ballooning
  (min 4096), 200 GB virtio-scsi disk on local-lvm, virtio NIC on
  vmbr0, QEMU guest agent enabled, UEFI (OVMF) with an EFI disk,
  secure boot off. Boot the stock NixOS minimal ISO.

**vault (DSM)**:

- Create a service account for the VM (e.g. `svc-alba-nix`), no admin
  rights, no home service needed.
- `media` share: give the service account read/write.
- Create a new shared folder `adult` (hide from My Network Places):
  permissions ONLY xentac + the service account; kids' accounts
  explicitly "No access".
- Move the adult annex repo out of `/var/services/homes/xentac/vault/`
  into the new share (repo directory move + fix the remote URL in the
  clones, or fresh clone + `git annex sync --content`; the homes copy
  can stay as an extra annex remote).
- Install git-annex on DSM (community package, or a minimal container)
  and add an hourly Task Scheduler job **run as root** for each working
  tree (`/volume1/media/Videos`, `/volume1/adult/adult`):

  ```sh
  tree=/volume1/adult/adult
  find "$tree" -path "$tree/.git" -prune -o ! -user xentac -exec chown xentac:users {} +
  sudo -u xentac sh -c "umask 022; cd '$tree' && git annex add . && git annex sync"
  ```

  Imports from alba-nix land owned by `svc-alba-nix`. `git annex add`
  chmods each file as it freezes it, and only the owner can chmod. The
  share ACL lets xentac read and write but not change permissions (no
  `C`), so the job chowns new files to xentac first. git itself runs as
  xentac: root-owned files in `.git` would break donatello's syncs. The
  chown leaves the inherited ACL alone, so the service account keeps
  access.
- The B2 side: create an application key scoped to bucket
  `backups-xentac`, prefix `restic/alba-nix/`.

**Tailscale admin console**:

- Create an auth key (or OAuth client) for the caddy tsnet nodes;
  it will register: sonarr, radarr, sabnzbd, whisparr-scenes,
  whisparr-movies, stash, grafana.
- ACL: deny kid/tagged devices access to the `stash`, `whisparr-scenes`
  and `whisparr-movies` nodes (allow only your own devices).

## 2. Fill in secrets

`sops secrets/alba-nix.yaml` and replace every CHANGEME:
stash login password, vault SMB credentials (the service account),
`TS_AUTHKEY`, B2 account id/key. The random keys (jwt, session,
grafana, restic password) are already real — don't touch them.

## 3. Install

From donatello, with the VM booted into the NixOS ISO (find its DHCP
address on the console):

```bash
nix run github:nix-community/nixos-anywhere -- --flake .#alba-nix root@<iso-ip>
```

disko partitions per `hosts/alba-nix/disko.nix` (virtio-scsi =
/dev/sda) and the system comes up on 192.168.1.23. Then let the host
decrypt its secrets:

```bash
ssh root@192.168.1.23 "nix-shell -p ssh-to-age --run 'ssh-to-age -i /etc/ssh/ssh_host_ed25519_key.pub'"
# add the age1... key to .sops.yaml (alba-nix anchor + rule), then:
sops updatekeys secrets/alba-nix.yaml
git commit -am "Add alba-nix sops recipient"
just deploy alba-nix
```

First boot checklist: `tailscale up` (the VM's own identity),
`btrfs subvolume list /` sanity check, confirm `/Videos` lists media.

Day-to-day updates are `just deploy alba-nix` (deploy-rs: builds on
donatello, pushes over SSH, and rolls back automatically if the new
config kills the connection). Prefer `just deploy-boot alba-nix` over
a flaky link — it stages the new generation for the next reboot
instead of switching live. Boat rule.

## 4. Migrate service state from baxter

Services on baxter stay off (they already are). Sources are the compose
volumes, staged at `root@alba-nix:~/baxter/` (copied from
`baxter:~/coding/nzb/`); targets are the module state dirs.
For each: stop the unit, copy, chown, start, click through the UI.

| service  | from (baxter)                  | to               | notes |
|----------|--------------------------------|------------------|-------|
| sonarr   | `sonarr/config/`               | `/var/lib/sonarr`  | linuxserver layout: sonarr.db + config.xml at top level; keep both. Library path /Videos unchanged. |
| radarr   | `radarr/config/`               | `/var/lib/radarr`  | same as sonarr |
| whisparr | `whisparr/config/`             | `/var/lib/whisparr` | hotio layout; library path /adult unchanged |
| sabnzbd  | nothing — config is fully declarative | `/var/lib/sabnzbd` | the module regenerates sabnzbd.ini from `media.nix` settings + the sops credential fragment on every start (web-UI config edits don't persist). Do NOT copy the old ini; it would be overwritten anyway. |
| stash    | `stash/config/` (root-owned)   | `/var/lib/stash`   | was `/root/.stash` in the container; DB + config.yml. `generated/`+`cache/` can be copied or left to regenerate; metadata dir too. This fixes the root-ownership mess for good. |

`chown -R <svc>:<its-group>` after each copy. The arr root folders and
sab categories all reference `/Videos`, `/adult`, `/downloads` — valid
by construction, no DB edits.

Verify auth: arrs keep their forms logins; stash now enforces the
sops-managed login (kid-proofing layer 4).

## 5. Acceptance tests

1. All seven names resolve and serve on the tailnet: sonarr, radarr,
   sabnzbd, whisparr-scenes, whisparr-movies, stash, grafana.
2. stash and the whisparrs are NOT reachable via 192.168.1.23:<port> (they
   bind localhost), and not reachable from a kid device via tailnet
   (ACL).
3. `sudo -u sonarr ls /adult` → permission denied;
   `sudo -u sonarr touch /Videos/x && rm` → works.
4. End-to-end: sab fetches a test nzb → sonarr imports to /Videos →
   run vault's annex job → file is annexed (read-only over SMB) and
   still plays in jellyfin.
5. `systemctl start restic-backups-state` → succeeds; `restic snapshots`
   via the wrapper shows it; restore one DB file to /tmp and open it.
6. Reboot with vault powered off/unreachable: VM boots, services start
   (mounts are nofail/automount), Grafana shows the gap.

## Phase 3a: Signal K (+ Node-RED) off the docker VM

Design: `docs/adr/0005`, `modules/server/signalk.nix`. Fresh state —
the old `.signalk` is a reference, not a source: reconfigure by hand with
both instances running and prune what you don't use. The only input is
victron-signalk (the GX's Signal K); the only sink is VictoriaMetrics.
InfluxDB stays on the docker VM as a read-only archive and does not get
an output plugin on the new instance.

1. **Free the name.** Already done: tsdproxy's `signalk` entry (the
   Victron's) removed and its node deleted in the Tailscale admin
   console. That name now belongs to the new instance; the Victron's is
   `victron-signalk`, served by caddy.nix as a cross-host backend
   (update the IP there when the GX moves).
2. **Deploy.** `just deploy alba-nix` brings up signalk.service (pulls
   the image on first start — needs internet), grafana on 3001, the
   `signalk` and `victron-signalk` tailnet nodes. Check:
   `https://signalk.stalk-darter.ts.net` and `http://192.168.1.23:3000`
   both answer; `avahi-browse -t _signalk-http._tcp` (or a boat app's
   server list) shows it from a LAN device.
3. **First run, in the Admin UI.** Create the admin user (prompted on
   first visit; it lands in `security.json` — journaled and backed up,
   no sops). Server → Settings: vessel name/MMSI, mDNS on, keep port
   3000. Server → Data Connections: add a *Signal K* connection to
   `http://192.168.1.207:3000` (victron-signalk) — same as on the old
   instance. Appstore: install the plugins you still want, including
   `@signalk/signalk-node-red`; Restart after each batch (the unit is
   `Restart=always` for exactly this).
4. **Compare side by side** against `signalk2`: Data Browser shows the
   same paths; `curl -s localhost:3000/signalk/v1/api/prometheus | sort`
   vs the same from `signalk2.stalk-darter.ts.net` — every metric the
   dashboards use (boat-internals, anchor, sailing) must be in both.
   Re-approve boat apps/devices as they connect (Security → Access
   Requests); the old tokens are not carried over. Node-RED flows:
   rebuild in the embedded editor (`/plugins/signalk-node-red/redAdmin`)
   — there is no standalone Node-RED to migrate.
5. **Cutover**, one commit: in `monitoring.nix` point the `signalk`
   scrape at `127.0.0.1:3000`, `scheme = "http"`; remove `signalk2` from
   tsdproxy on the docker VM and delete its node. Deploy. Stop the old
   container; keep its `.signalk` dir a month for "what was that
   setting" lookups.
6. `just drift-config alba-nix signalk` shows every UI edit since the
   last restart, same as the media services.

Updating: the version is the tag in `signalk.nix` (the Admin UI
footer says when a new one exists). Bump, `just deploy`. Plugins update
through the Appstore as before.

## Phase 3b: calibre-web off the docker VM

Design: `modules/server/calibre-web.nix` (read-only `/books` mount in
`mounts.nix`). Books are single-writer: calibre on donatello edits, the
git-annex assistant pushes to vault, and alba-nix only reads vault's
checkout.

1. **vault (DSM).** Create a shared folder `calibre`: xentac read/write,
   the service account (`svc-alba-nix`) **read-only**. The repo lives at
   `/volume1/calibre/calibre`, one level below the share root, and
   `mounts.nix` mounts that subdirectory as `/books`. Move it there from
   `homes/xentac/calibre`, or clone it fresh and `git annex sync
   --content`. On donatello: `git -C ~/calibre remote set-url vault
   vault-annex:/volume1/calibre/calibre`, restart the assistant so it picks up
   the new URL (`just assistant-stop && just assistant-start` in
   `~/calibre`), then `git annex sync` to check it still talks to vault.
2. **Keep vault's checkout current.** Add an hourly Task Scheduler job
   `umask 022; cd /volume1/calibre/calibre && git annex sync --no-commit
   --no-pull --no-push`.
   The umask matters: DSM's default is 077, which checks out author
   directories (and the unlocked metadata.db) unreadable to the service
   account. Fix an existing tree with `find . -path ./.git -prune -o !
   -type l -exec chmod go+rX {} +`. The flags make it a local merge only:
   nobody writes into this checkout (no `add`, no commit), and it never
   talks to vault's own remotes. It still merges `synced/master` and
   `synced/git-annex`, which is the point.
   Without it vault's `master` never advances. As of Oct 2026 it was
   still at Apr 11 (in donatello's last-fetched view) while
   `synced/master` had donatello's latest, so the docker calibre-web is
   almost certainly showing an April library too. Check: `git -C ~/calibre fetch vault && git -C
   ~/calibre log -1 vault/master` matches local `master`.
3. **Migrate state.** Stop the docker container and copy its
   `/config/app.db` (and `gdrive.db` if present) to
   `/var/lib/calibre-web/`, then `chown -R calibre-web:calibre-web`.
   The unit rewrites the library path, port and upload flag in app.db
   at every start, so the container's `/books` setting doesn't matter.
   Skip the copy for a fresh start: the first login is `admin` /
   `admin123`, so change it right away.
4. **Free the name and deploy.** Remove the container's tsdproxy entry
   and delete its node in the Tailscale admin console if it was
   called `calibre-web`, then `just deploy alba-nix`.
5. **Check.** `https://calibre-web.stalk-darter.ts.net` lists the
   library and a book downloads and opens in the reader. In Admin →
   Users, every user has Edit/Upload/Delete unticked. `sudo -u
   calibre-web touch /books/x` fails with "Read-only file system". Kobo
   or OPDS clients need their URL updated.
6. **End to end.** Add a book in calibre on donatello and close calibre
   (the assistant commits on close). After the next vault job, the book
   shows up in calibre-web *without* restarting it. If it doesn't,
   calibre-web is holding the replaced metadata.db open. Try Admin →
   Reconnect Calibre Database, and if that works, add a timer that does
   the same (or restarts the unit) just after the vault job.

## Paperless

Design: `modules/server/paperless.nix`, `docs/adr/0009`; the workflow is
`docs/paperless.md`. The admin password is already in
`secrets/alba-nix.yaml` (`paperless/admin-password`; read it with
`sops -d`).

1. **vault (DSM).** Create a shared folder `paperless`: the service
   account (`svc-alba-nix`) read/write, xentac **read-only** (to browse
   the export from donatello). Turn on Snapshot Replication for it:
   daily, keep 30. That's the undo for the export's `--delete`.
2. **Tailnet ACL.** Allow only your and your wife's devices to reach the
   `paperless` node, like fava.
3. **Deploy.** `just deploy alba-nix`. Paperless creates the superuser
   `xentac` on first start.
4. **Accounts.** At `https://paperless.stalk-darter.ts.net`: create a
   `household` group with view/change/add/delete on everything, and a
   second user in it for your wife. Under each user's profile set
   default permissions to share with the group.
5. **Inbox tag and `expires`.** Create the `inbox` tag with "Inbox tag"
   ticked, the starter document types and tags from `docs/paperless.md`,
   a date custom field `expires`, a document link custom field
   `replaced by`, and the Inbox and Expiring saved views.
6. **Mail.** Create the GMX account, enable IMAP in its settings and
   make an app password. In paperless, under Mail: an account
   (`imap.gmx.com`, or `imap.gmx.net` for a .net/.de address; 993, SSL) and a rule: folder INBOX, attachments
   only, PDF/image types, action "move to folder" `Processed` (create
   it in GMX first), assign tag `inbox`.
7. **Check.** Forward a PDF to the GMX address: within ~10 min it's in
   the inbox, OCR'd. Upload a phone photo from the app. The next
   morning, `/volume1/paperless` on vault has `manifest.json` and
   `2026/<correspondent>/<title>.pdf`, and `systemctl status
   paperless-export` shows success.

## Two whisparrs: scenes and movies

Design: docs/adr/0006 and `modules/server/whisparr.nix`. v2 becomes
`whisparr-scenes` (root `/adult/scenes`), v3 is the new
`whisparr-movies` (root `/adult/movies`). Do the steps in order.

1. **Tailscale ACL first.** Add `whisparr-scenes` and
   `whisparr-movies` to the kid-device deny rule next to `stash`, so
   the new nodes are never reachable from a kid device, even briefly.
2. **Quiesce.** In whisparr's UI, go to Settings → Media Management and
   check that "Unmonitor Deleted Episodes" is **off**. Otherwise a
   rescan during the move would unmonitor every scene. Then `systemctl
   stop whisparr` on alba-nix, and on vault disable the hourly annex
   job for `/volume1/adult/adult`.
3. **Restructure `/adult` on vault.** Run this as xentac, the owner of
   `.git`. Run the annex job's `git annex add . && git annex sync` once
   by hand first, so the tree is clean (`git status` empty). Then:

   ```sh
   umask 022   # DSM's default 077 would make scenes/ untraversable for svc-alba-nix
   cd /volume1/adult/adult
   mkdir scenes
   # dry run: review the list, delete any line that isn't a site folder
   for d in */; do [ "$d" = scenes/ ] || printf 'git mv "%s" scenes/\n' "${d%/}"; done > /tmp/mv.sh
   sh /tmp/mv.sh
   git commit -m "Move site folders under scenes/"
   find scenes -xtype l | head   # must print nothing
   ```

   Moving a site down one level would break its annex symlinks (they
   are relative). The commit's annex pre-commit hook rewrites them,
   which is why this has to be a `git mv` on vault and never a move
   from whisparr or over SMB. If `find` prints anything, run `git annex
   fix scenes` and commit. Re-enable the annex job.
4. **Deploy and move whisparr's state.** `just deploy alba-nix` starts
   both new units, and whisparr-scenes starts out with an empty DB.
   Stop it straight away and swap in the old state:

   ```bash
   systemctl stop whisparr-scenes
   rm -rf /var/lib/whisparr-scenes
   mv /var/lib/whisparr/.config/Whisparr /var/lib/whisparr-scenes
   chown -R whisparr-scenes:media /var/lib/whisparr-scenes
   chmod 700 /var/lib/whisparr-scenes
   systemctl start whisparr-scenes
   ```

   In the Tailscale admin console, delete the old `whisparr` node.
5. **Repoint whisparr-scenes** (`https://whisparr-scenes.stalk-darter.ts.net`)
   right after step 4. Until this is done, every site's path points at
   a folder that no longer exists, so a scheduled rescan would mark
   scenes missing and the next RSS sync would grab them again. If you
   can't do it immediately, disable the sab download client first and
   turn it back on after the rescan below. The old login still works.
   Order matters, because the mass editor only offers registered root
   folders:
   1. Settings → Media Management → Root Folders: add `/adult/scenes`.
   2. Series → Select All → Edit → Root Folder `/adult/scenes` →
      **"No, I'll move the files myself"**.
   3. Remove the old `/adult` root folder (otherwise `scenes/` and
      `movies/` show up as unmapped folders).
   4. Settings → Download Clients: change sab's category to
      `adult-scenes`.
   5. Refresh & Scan all: no scene should show as missing.
6. **Set up whisparr-movies** (`https://whisparr-movies.stalk-darter.ts.net`).
   First start asks you to create a login, so use forms auth like the
   others. Create the root folder with `sudo -u whisparr-movies mkdir
   /adult/movies`, then add it under Settings → Media Management. Add
   the download client: sabnzbd, host `127.0.0.1`, port 8080, URL base
   `/sabnzbd`, sab's API key, category `adult-movies`. Copy the
   indexers over from whisparr-scenes by hand. **Movies only**: never
   add a studio or performer here (docs/adr/0006).
7. **Stash.** Run a scan on `/adult`. Moved scenes are matched by
   fingerprint and keep their metadata, so nothing should turn up as
   new. Under Settings → Metadata Providers, ThePornDB is listed and
   its test passes. Grab a movie from whisparr-movies and run Identify
   on it with ThePornDB. If TPDB's stash-box only returns scenes,
   attach the movie to a Group with the community TPDB scraper instead.
8. **Check.** `ss -ltnp | grep -E ':(6969|6970) '` shows two different
   processes, both on 127.0.0.1 (v3's port comes only from the env
   override). `sudo -u whisparr-movies ls /adult` works and `sudo -u
   sonarr ls /adult` is denied.
9. **Later cleanup.** When nothing in sab's queue or history uses the
   `adult` category, remove it from `media.nix`. After a week of
   whisparr-scenes working fine, delete `/var/lib/whisparr`.

## Phase 2 (when ready): qbittorrent + AirVPN

Subscribe, reserve a static forwarded port, drop the wireguard config
in sops. Then a `modules/server/qbittorrent.nix`: wireguard interface
in a dedicated network namespace, `services.qbittorrent` unit joined to
it (`NetworkNamespacePath`), no default route in the netns except the
tunnel (structural kill-switch), web UI bridged out, listen port = the
reserved AirVPN port. Publish the UI via caddy.nix like the others.
