# 0008 — proxmox is monitored over the LAN, with apt-only host software

Date: 2026-10-18. Status: accepted.

## Context

alba-nix is the boat's monitoring hub; proxmox (the hypervisor under it)
is a hand-managed appliance outside this repo. Its host-level signals —
io pressure, NVMe temperature/throttling, host RAM, guest ballooning —
are what explained the Oct 2026 guest slowdowns, and none of them are
visible from inside a guest. Two flows are needed: alba-nix pulls
metrics from proxmox, and proxmox pushes its journal to VictoriaLogs.

The default for this repo's hosts is tailscale everywhere, and proxmox
is on the tailnet.

## Decision

Both flows use raw LAN addresses (proxmox 192.168.1.20, alba-nix
192.168.1.23), each side firewalled to the other's address, not the
tailnet. VictoriaLogs listens on the LAN, reachable only from proxmox.

On proxmox, only Debian packages are installed (node_exporter, its
textfile collectors for SMART/NVMe, systemd-journal-remote); nothing is
hand-installed beyond the existing backup script. The guest view comes
from the PVE API, polled by an exporter on alba-nix with a read-only
`PVEAuditor` token. The host's restic job reports itself through the
textfile collector, emitting restic-exporter 1.7.0's metric names and
labels so both hosts' backups share one dashboard.

## Consequences

- Same rule as 0004: the monitor must not depend on what it monitors. A
  tailscaled hiccup or an offline uplink would otherwise blank host
  metrics and logs exactly when they are being read. Smokeping already
  probes by LAN IP for the same reason.
- LAN traffic is unencrypted. Accepted: it never leaves the boat, and
  proxmox's root can already read alba-nix's disk.
- No exporter on proxmox needs manual updating; apt keeps them current.
  The cost is SMART metrics under the collector scripts' names rather
  than smartctl_exporter's — nothing else reports SMART that way anyway
  (alba-nix is a VM, vault goes through SNMP).
- The textfile restic metrics only change when the backup runs; their
  shape must track restic-exporter if alba-nix's exporter or the
  dashboard moves to 2.x.
