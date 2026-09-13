# Glossary

Canonical vocabulary for this repo. Terms only — design decisions live in
`docs/adr/`, operations in `docs/`.

- **alba** — the boat. The location for the whole 192.168.1.0/24 LAN
  (Proxmox, vault, the VMs). Location token in server names.
- **vault** — the Synology NAS at 192.168.1.223. An appliance: never
  nixified, holds the media shares and the authoritative git-annex repos.
- **alba-nix** — the NixOS boat-services VM on Alba's Proxmox
  (`hosts/alba-nix`). Runs the media stack now; absorbs the docker VM's
  services over time.
- **donatello** — Jason's Framework 13 laptop (`hosts/donatello`).
  Deliberately an island: its monitoring and backups are self-contained.
- **baxter** — Jason's previous laptop (Ubuntu). Source of the migrated
  media-stack state; not managed by this repo.
- **naming scheme** — servers are named `<location>-<purpose>`
  (e.g. alba-nix); personal machines keep TMNT names.
- **annex-backed library** — a media tree (`/Videos`, `/adult`) whose
  authoritative copy is a *locked* git-annex working tree on vault.
  Clients see annexed files over SMB as read-only regular files; only
  vault runs git-annex commands.
- **integrated into the annex** — the end state of a download: imported
  into an annex-backed library over SMB and then annexed by vault's
  scheduled job. Until then a file in `/downloads` is temporary scratch.
- **media / adult** — the two permission domains on alba-nix. `media`
  (sabnzbd, sonarr, radarr, whisparr) shares `/downloads` and `/Videos`;
  `adult` (whisparr, stash) is the only group able to traverse `/adult`.
- **published service** — a service given its own tailnet hostname by the
  caddy-tailscale layer (`modules/server/caddy.nix`).
