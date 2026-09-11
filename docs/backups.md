# Backup design: one restic repo per host

Decision from September 2026, recorded before a second host exists so
the reasoning isn't lost. `modules/nixos/backups.nix` currently
hardcodes `b2:restic-donatello:`; when another machine joins the flake,
switch to hostname-derived sub-paths rather than sharing one repo.

## The decision

Each host gets its **own restic repository**, spelled as a sub-path in
a single shared B2 bucket:

```nix
repository = "b2:xentac-backups:restic/${config.networking.hostName}";
```

Restic treats each sub-path as a completely independent repository —
its own password, locks, snapshots, and retention. One bucket is chosen
over bucket-per-host only for convenience: the bucket is created once,
and with `initialize = true` a new host creates its repo under its own
prefix on first run with no B2 console work (beyond its application
key).

## Why not one shared repo for all hosts

- **Prune contention.** `restic prune` takes an exclusive lock on the
  whole repo. Daily timers on multiple machines pruning one repo will
  collide and fail runs. Separate repos keep each host's schedule
  independent.
- **Blast radius.** A repo has one password, and the systemd unit has
  forget/prune rights. With a shared repo, one compromised machine can
  read *and delete* every host's backups. B2 application keys can be
  restricted to a bucket **and a file-name prefix**, so each host's key
  is scoped to just its own `restic/<hostname>/` path.
- **Simpler retention.** Shared repos need careful `--group-by host`
  behavior in forget policies; separate repos have no such footgun.
- **Dedup isn't worth it.** Cross-host deduplication is the only thing
  a shared repo buys, and home directories on different machines rarely
  overlap enough to matter. Bucket cost is a wash — B2 buckets are
  free.

The trade-off accepted: restoring host A's files onto host B means
pointing restic at A's repo manually. Minor, not a blocker.

## The exclude list stays shared

Restic excludes are glob patterns and a pattern matching nothing is a
free no-op, so the module's list is just the union of what any host
might have — `xentac/.npm` on a machine without one is harmless. The
list is also host-portable already: every path is anchored at the fixed
`/.snapshots/restic-home` snapshot prefix, identical on every host.

Two escape hatches for genuinely host-specific exclusions:

- NixOS merges list options, so a host file can append with
  `services.restic.backups.home.exclude = [ "..." ];` — no
  restructuring needed.
- `--exclude-if-present .nobackup` is already passed: drop a
  `.nobackup` marker file in a directory on one machine and it is
  excluded there without touching the config anywhere.
