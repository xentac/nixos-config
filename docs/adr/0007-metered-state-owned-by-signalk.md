# 0007 — Metered state is owned by Signal K, fails closed, and is consumed via `metered.target`

Date: 2026-10-18. Status: accepted.

## Context

Offshore (beyond territorial waters) Starlink bills per byte, so bulk
transfers — sabnzbd downloads, restic, the git-annex assistant — must
stand down. signalk's starlink-offshore plugin already knows the boat's
position relative to the 12 nm line (`navigation.currentTerritorialSea`,
`navigation.distanceToLeaveTerritorialSea`). Several hosts need to act on
it: alba-nix, and donatello while it is on the boat network.

The concept is modelled as **metered** — a property of the uplink — not
as "offshore": offshore is one input, a manual override is another, and
later inputs (another uplink, Starlink's own status) shouldn't need a
new concept.

Alternatives: (a) a host-owned state, e.g. a `metered.target` on
alba-nix set by `systemctl` — NixOS-native, but overriding needs SSH and
nothing on the boat side (KIP, WilhelmSK, Grafana) can see or toggle it.
(b) every consumer reads the offshore flag itself — no shared seam, and
each one reimplements the fail-safe and drifts.

## Decision

signalk is the single source of truth. A Node-RED flow inside it derives
`network.metered` from the offshore input (1 nm buffer inside the line;
10 continuous minutes back inside before it clears) and a three-way
`network.meteredOverride` (`auto` | `metered` | `unmetered`, PUT-able,
persisted in Node-RED context). A forced `unmetered` — the override that
spends money — expires on the next offshore transition or after 24 h; a
forced `metered` lasts until cleared. The flow republishes the state
every minute as a heartbeat, plus `network.meteredReason` and
`network.meteredOverrideExpires`, and raises
`notifications.network.metered` on transitions.

On each consuming NixOS host one shared watcher module turns that into
`metered.target`, active whenever the state is metered **or unknown**:
signalk unreachable, a value older than 5 minutes, or the watcher itself
dead all count as metered. Consumers attach with ordinary systemd
relationships (`ExecCondition=` for timers, a start/stop unit for
daemons). Automation only undoes what it did itself: it resumes sabnzbd
or restarts the git-annex assistant only if it was the one that paused
or stopped it.

On donatello the watcher runs only while a known boat NetworkManager
connection is active — metered describes the boat's uplink, not the
laptop's — so ashore it neither fails closed nor obeys the boat's
offshore state over tailscale.

## Consequences

- Fail closed means a dead or hung signalk pauses downloads even in
  harbour. Accepted: the alternative is spending paid data unnoticed
  overnight on a passage.
- The derivation lives in Node-RED, not in this repo. `flows.json` is
  journalled by config-history and a reference copy is kept in the repo;
  if the logic outgrows that, a `signalk-metered` plugin can replace the
  flow without changing the path contract.
- A manual Resume in sabnzbd's UI while metered is respected; the
  override is the sanctioned way to spend data, not the only one.
- Backups are skipped for the length of a passage. Visibility is a
  Grafana "last snapshot age" panel until real alerting exists.
- Devices outside this repo (phones, vault, the Proxmox host) are not
  covered by this seam.
