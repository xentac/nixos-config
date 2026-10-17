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
- **scene** — a single release from an adult site; lives under
  `/adult/scenes/<site>/`. A site is tracked like a series, its scenes
  like episodes.
- **movie** — a full-length adult release, not tied to a site's scene
  feed; lives under `/adult/movies/`. Scenes and movies are tracked by
  separate instances and never both by one.
- **media / adult** — the two permission domains on alba-nix. `media`
  (sabnzbd, sonarr, radarr, both whisparrs) shares `/downloads` and
  `/Videos`; `adult` (whisparr-scenes, whisparr-movies, stash) is the
  only group able to traverse `/adult`.
- **whisparr-scenes / whisparr-movies** — the two Whisparr instances:
  one tracks sites and their scenes, the other only movies.
- **published service** — a service given its own tailnet hostname by the
  caddy-tailscale layer (`modules/server/caddy.nix`).
- **docker-vm** — the Ubuntu VM on Alba's Proxmox that runs the legacy
  compose stack (tsdproxy, InfluxDB, the old Signal K). Being drained
  into alba-nix service by service; not managed by this repo.
- **signalk** — *the* Signal K server for the boat: the aggregating
  instance on alba-nix that apps, dashboards and Node-RED mean by
  "Signal K". Its only data input is victron-signalk.
- **victron-signalk** — the Signal K instance built into the Victron GX
  (Venus OS). The sole upstream source of boat data; an appliance,
  never configured from this repo.
