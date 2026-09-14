# alba-nix: provisioning and migration runbook

The boat-services VM. Design context: `CONTEXT.md` (vocabulary) and
`docs/adr/0001`–`0004` (why it's shaped this way). This file is the
do-it order of operations. Phase 1 scope: sabnzbd + sonarr + radarr +
whisparr + stash, SMB libraries from vault, self-monitoring, restic to
B2. qbittorrent + AirVPN is phase 2; absorbing the docker VM is later.

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
  and add an hourly Task Scheduler job for each working tree
  (`media/Videos`, `adult`):
  `cd <tree> && git annex add . && git annex sync`
- The B2 side: create an application key scoped to bucket
  `backups-xentac`, prefix `restic/alba-nix/`.

**Tailscale admin console**:

- Create an auth key (or OAuth client) for the caddy tsnet nodes;
  it will register: sonarr, radarr, sabnzbd, whisparr, stash, grafana.
- ACL: deny kid/tagged devices access to the `stash` and `whisparr`
  nodes (allow only your own devices).

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
volumes in `baxter:~/coding/nzb/`; targets are the module state dirs.
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

1. All six names resolve and serve on the tailnet: sonarr, radarr,
   sabnzbd, whisparr, stash, grafana.
2. stash and whisparr are NOT reachable via 192.168.1.23:<port> (they
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

## Phase 2 (when ready): qbittorrent + AirVPN

Subscribe, reserve a static forwarded port, drop the wireguard config
in sops. Then a `modules/server/qbittorrent.nix`: wireguard interface
in a dedicated network namespace, `services.qbittorrent` unit joined to
it (`NetworkNamespacePath`), no default route in the netns except the
tunnel (structural kill-switch), web UI bridged out, listen port = the
reserved AirVPN port. Publish the UI via caddy.nix like the others.
