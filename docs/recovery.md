# Recovering from the restic backups

The disaster-recovery runbook. It assumes the worst case: the machine
is gone, and all you have is a clone of this repo and the **admin age
key** from the Bitwarden vault. That is enough — `.sops.yaml` encrypts
every `secrets/<host>.yaml` to the admin key as well as to the host
keys, so the restic credentials are always reachable without any
surviving machine.

Two scenarios, in increasing order of effort:

1. **Read the data somewhere else** — restore either host's files into
   a directory on any machine, just to get at the contents.
2. **Full system recovery** — rebuild the host from this repo, then put
   its state back so it carries on as before.

## What is in each repo

One restic repository per host, as sub-paths of the shared B2 bucket
`backups-xentac` (rationale: [backups.md](backups.md)). Both back up
from a read-only btrfs snapshot taken at a fixed path, so files are
stored under that snapshot prefix, **not** their live paths:

| host | repository | stored path | is really | plus (at real paths) |
| --- | --- | --- | --- | --- |
| donatello | `b2:backups-xentac:restic/donatello/` | `/.snapshots/restic-home/...` | `/home/...` | `/etc/ssh`, `/etc/NetworkManager/system-connections` |
| alba-nix | `b2:backups-xentac:restic/alba-nix/` | `/.snapshots/restic-state/...` | `/var/lib/...` | `/etc/ssh` |

`/etc/ssh` rides along deliberately: the SSH host key is also the
host's sops decryption key, so restoring it restores the machine's
ability to decrypt everything in `secrets/` unattended — no
`.sops.yaml` re-keying needed after a rebuild.

Not in any backup, by design: donatello's `/etc` beyond the two dirs
above (generated from this repo), alba-nix's `/downloads` (scratch),
stash `generated/`+`cache/` (derived), and the media libraries
themselves (vault's git-annex problem, not these hosts').

## Step 0: credentials (both scenarios)

On any machine with nix (a NixOS live ISO works — `nix shell` is
available there):

```bash
nix shell nixpkgs#restic nixpkgs#sops nixpkgs#age
git clone https://github.com/xentac/nixos-config && cd nixos-config

mkdir -p ~/.config/sops/age
# Paste the age secret key from Bitwarden into ~/.config/sops/age/keys.txt,
# then confirm it is the admin key .sops.yaml expects:
age-keygen -y ~/.config/sops/age/keys.txt
# must print: age1t7edkdrvclrdg80enffqxwqde2cacs6d9zrxuyn22ghleksf4slqgkyyh4
```

Decrypt the two restic credentials **from the secrets file of the host
you are restoring** — the B2 application key in each file is scoped to
that host's `restic/<hostname>/` prefix, so donatello's key cannot open
alba-nix's repo or vice versa:

```bash
HOST=donatello   # or alba-nix
sops -d --extract '["restic"]["environment"]' secrets/$HOST.yaml > /tmp/restic.env
sops -d --extract '["restic"]["password"]'    secrets/$HOST.yaml > /tmp/restic.pw
chmod 600 /tmp/restic.env /tmp/restic.pw

set -a; source /tmp/restic.env; set +a    # B2_ACCOUNT_ID / B2_ACCOUNT_KEY
export RESTIC_REPOSITORY="b2:backups-xentac:restic/$HOST/"
export RESTIC_PASSWORD_FILE=/tmp/restic.pw

restic snapshots    # sanity check: lists snapshots, newest last
```

(On the host itself, day to day, none of this is needed — the module
generates a `restic-home` / `restic-state` wrapper with repo and
credentials already wired in.)

## Scenario 1: read the data on another machine

With the environment from step 0, restore into a directory:

```bash
restic restore latest --target /tmp/recovered
```

Everything lands under the stored prefixes, so:

- donatello's `/home/xentac/Documents` is at
  `/tmp/recovered/.snapshots/restic-home/xentac/Documents`
- alba-nix's `/var/lib/sonarr` is at
  `/tmp/recovered/.snapshots/restic-state/sonarr`

To pull just one directory instead of the whole snapshot, `--include`
with the stored path:

```bash
restic restore latest --target /tmp/recovered \
    --include /.snapshots/restic-home/xentac/Documents
```

Useful variants:

```bash
restic snapshots                          # pick an older snapshot ID than latest
restic ls latest | less                   # browse contents without restoring
restic find '*wg0.nmconnection*'          # locate a file across snapshots
restic mount /mnt/restic                  # FUSE-mount all snapshots read-only
```

`restic mount` is the nicest way to *read* data: every snapshot appears
as a directory tree and nothing is copied until you `cp` it out. It
needs FUSE, which any NixOS machine has.

Ownership note: restic restores numeric uid/gids from the original
host. On a different machine those numbers may map to other users (or
nobody); that's cosmetic for reading — use `sudo` to browse, and
`chown` whatever you copy out.

## Scenario 2: full system recovery

The shape is the same for both hosts:

1. Reinstall the OS from this repo (it declaratively rebuilds
   everything except the backed-up state).
2. Restore `/etc/ssh` from the backup, so the host is again a sops
   recipient and can decrypt its own secrets.
3. Restore the state payload (`/home` or `/var/lib`).
4. Rebuild/reboot; the daily restic timer resumes against the same
   repo (parent-snapshot matching still works because the snapshot
   paths are fixed).

### donatello (Framework laptop)

1. **Reinstall** per [install.md](install.md), through first boot.
2. **Get credentials** as in step 0 (on the freshly installed machine
   is fine), then restore into a staging directory:

   ```bash
   sudo --preserve-env=RESTIC_REPOSITORY,RESTIC_PASSWORD_FILE,B2_ACCOUNT_ID,B2_ACCOUNT_KEY \
       restic restore latest --target /mnt/staging
   ```

3. **Host identity first** — put the old SSH host keys back and
   re-activate so sops-nix can decrypt `/run/secrets` again:

   ```bash
   sudo cp -a /mnt/staging/etc/ssh/ssh_host_* /etc/ssh/
   sudo systemctl restart sshd
   cd ~/coding/nixos-config && just switch
   ```

   (Without this step the machine has a brand-new host key and every
   secret-using service fails; the alternative — adding the new key to
   `.sops.yaml` + `sops updatekeys` — works too but re-keys for no
   reason.)

4. **Home and network config:**

   ```bash
   sudo rsync -aHAX /mnt/staging/.snapshots/restic-home/ /home/
   sudo rsync -aHAX /mnt/staging/etc/NetworkManager/system-connections/ \
       /etc/NetworkManager/system-connections/
   sudo systemctl restart NetworkManager
   ```

   The `xentac` uid is 1000 on any fresh install, so ownership survives
   as-is. WiFi passwords and imported VPN profiles come back with the
   NetworkManager connections.

5. **Verify, then clean up:** log in, spot-check `~/Documents`, run
   `sudo systemctl start restic-backups-home` and confirm a new
   snapshot appears; then remove `/mnt/staging`.

### alba-nix (boat-services VM)

1. **Recreate the VM and install** per [alba-nix.md](alba-nix.md) §1
   and §3 — but restore the host keys *before* installing and hand
   them to nixos-anywhere, so the system comes up already able to
   decrypt its secrets. On donatello (or wherever step 0 ran with
   `HOST=alba-nix`):

   ```bash
   restic restore latest --include /etc/ssh --target /tmp/alba-keys
   mkdir -p /tmp/alba-extra/etc/ssh
   cp -a /tmp/alba-keys/etc/ssh/ssh_host_* /tmp/alba-extra/etc/ssh/
   nix run github:nix-community/nixos-anywhere -- \
       --flake .#alba-nix --extra-files /tmp/alba-extra root@<iso-ip>
   ```

   (Skip the ssh-to-age / `sops updatekeys` dance from the install
   runbook — the restored key is already a recipient. If you forgot
   `--extra-files`, copy the keys over afterwards and
   `just deploy alba-nix` again.)

2. **Restore `/var/lib`.** Stop the services so nothing writes sqlite
   files mid-copy, restore, fix ownership, reboot:

   ```bash
   ssh root@192.168.1.23
   systemctl stop sonarr radarr whisparr sabnzbd stash grafana \
       victoriametrics victorialogs caddy

   # credentials as in step 0 (or scp /tmp/restic.env + .pw over)
   restic restore latest --target /mnt/staging
   rsync -aHAX /mnt/staging/.snapshots/restic-state/ /var/lib/

   # uid/gid numbers from the old install may not match the new one
   # (groups per media.nix: arrs + sab are :media, stash is :adult):
   for svc in sonarr radarr whisparr sabnzbd; do
       chown -R "$svc:media" "/var/lib/$svc"
   done
   chown -R stash:adult /var/lib/stash
   chown -R grafana:grafana /var/lib/grafana
   reboot
   ```

   The reboot (rather than starting units by hand) lets systemd bring
   everything up in order against the restored state. stash regenerates
   `generated/` and `cache/` on its own — they were excluded from the
   backup on purpose.

3. **Verify** with the acceptance tests in [alba-nix.md](alba-nix.md)
   §5 — at minimum: the tailnet names serve, the arrs show their
   history, and `systemctl start restic-backups-state` produces a new
   snapshot.

## Things to check *before* you ever need this

- The Bitwarden copy of the age key actually is the admin key
  (`age-keygen -y` check from step 0).
- `restic snapshots` from a non-host machine works for both repos —
  proves the credentials in sops are current and the B2 keys aren't
  expired. Worth doing after any B2 key rotation.
- A test restore of one file opens correctly (alba-nix acceptance test
  5 does this).
