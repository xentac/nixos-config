# Offsite backups of the VM's state: restic -> B2, one repo per host under
# a shared bucket (docs/backups.md). The payload here is /var/lib — every
# service database and config (arrs, stash, sab, Grafana, the Victoria
# TSDBs) — copied from a read-only btrfs snapshot so live sqlite files are
# captured consistently.
#
# NOT backed up, on purpose:
#   /downloads          — scratch; re-downloadable by definition
#   stash generated+cache — derived data, stash regenerates it
#   media libraries     — vault's problem (git-annex), not this host's
{ config, pkgs, ... }:
{
  sops.secrets."restic/password" = { };
  sops.secrets."restic/environment" = { };

  services.restic.backups.state = {
    repository = "b2:backups-xentac:restic/${config.networking.hostName}/";
    passwordFile = config.sops.secrets."restic/password".path;
    environmentFile = config.sops.secrets."restic/environment".path;
    initialize = true; # create the repo on first run if it doesn't exist

    # Snapshot at a FIXED path so restic's parent-snapshot matching and
    # dedup keep working run to run. The delete first handles a previous
    # run that died before cleanup.
    backupPrepareCommand = ''
      ${pkgs.btrfs-progs}/bin/btrfs subvolume delete /.snapshots/restic-state 2>/dev/null || true
      ${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot -r /var/lib /.snapshots/restic-state
    '';
    # /etc/ssh rides along: the host key is also the sops decryption key,
    # so restoring it restores access to every secret in this repo.
    paths = [
      "/.snapshots/restic-state"
      "/etc/ssh"
    ];
    backupCleanupCommand = ''
      ${pkgs.btrfs-progs}/bin/btrfs subvolume delete /.snapshots/restic-state
    '';

    extraBackupArgs = [
      "--exclude-caches"
      "--exclude-if-present"
      ".nobackup"
    ];
    exclude = [
      "/.snapshots/restic-state/stash/generated"
      "/.snapshots/restic-state/stash/cache"
      # systemd's own state that's meaningless on restore:
      "/.snapshots/restic-state/systemd/coredump"
    ];

    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      # Don't sync minute-zero with every other machine on the boat link.
      RandomizedDelaySec = "30m";
    };
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 6"
    ];
  };
}
