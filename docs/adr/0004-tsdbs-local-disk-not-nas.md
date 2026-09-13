# 0004 — Monitoring TSDBs on local disk + restic, not on the NAS

Date: 2026-09-13. Status: accepted.

## Context

The docker VM keeps its influxdb/monitoring data on an NFS mount from
vault, making the NAS the single copy. alba-nix runs its own
VictoriaMetrics/VictoriaLogs stack and will become the boat's
monitoring hub; the question was whether its TSDBs should live on vault
the same way.

## Decision

TSDBs live on alba-nix's local btrfs (`/var/lib`, its own subvolume)
and are covered by the nightly snapshot→restic→B2 job like all other
service state.

## Consequences

- The monitor does not depend on the thing it monitors: a vault outage
  is *recorded* instead of taking monitoring down with it (NFS-wedged
  daemons don't die cleanly).
- Upstream agrees: VictoriaMetrics tolerates NFS but recommends block
  storage, and has a history of NFS-specific crash bugs.
- Durability is better than the status quo, not worse: B2 offsite copy
  nightly versus a single NAS-resident copy.
- The same reasoning applies to influxdb/signalk data when those
  migrate from the docker VM — to be confirmed then (signalk write
  volume is a different profile).
