# Snapshots (btrbk) and offsite backups (restic). Your Ubuntu box runs
# btrbk.timer daily and resticprofile timers; the restic profiles were
# root-only so they could not be read — fill in the TODOs.
{ config, pkgs, ... }:
{
  # Local btrfs snapshots of / and /home into /.snapshots, daily.
  # Create the directory once: sudo btrfs subvolume create /.snapshots
  services.btrbk.instances.local = {
    onCalendar = "daily";
    settings = {
      timestamp_format = "long";
      snapshot_preserve_min = "2d";
      snapshot_preserve = "14d 8w 6m";
      volume."/" = {
        snapshot_dir = ".snapshots";
        subvolume = {
          "." = { }; # the @ root subvolume
          "home" = { }; # @home
        };
      };
    };
  };

  # Offsite restic backup of /home, taken from a read-only btrfs snapshot so
  # the copy is consistent even while you're working (what resticprofile did
  # on Ubuntu). The repo password and B2 credentials come from sops
  # (secrets/donatello.yaml); edit them with `sops secrets/donatello.yaml`.
  #
  # Paths inside the repo are prefixed /.snapshots/restic-home instead of
  # /home; restore with e.g.
  #   sudo restic-home restore latest --target /tmp/r \
  #        --include /.snapshots/restic-home/xentac/Documents
  # (`restic-home` is a wrapper the module generates with repo + password set.)
  #
  # The environment secret is an env-file (B2_ACCOUNT_ID=... / B2_ACCOUNT_KEY=...).
  sops.secrets."restic/password" = { };
  sops.secrets."restic/environment" = { };

  services.restic.backups.home = {
    # One repo per host via sub-paths — see docs/backups.md for the rationale.
    repository = "b2:backups-xentac:restic/${config.networking.hostName}/";
    passwordFile = config.sops.secrets."restic/password".path;
    environmentFile = config.sops.secrets."restic/environment".path;
    initialize = true; # create the repo on first run if it doesn't exist

    # Read-only snapshot at a FIXED path so restic's parent-snapshot
    # matching and dedup keep working run to run. The delete first handles
    # a previous run that died before cleanup.
    backupPrepareCommand = ''
      ${pkgs.btrfs-progs}/bin/btrfs subvolume delete /.snapshots/restic-home 2>/dev/null || true
      ${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot -r /home /.snapshots/restic-home
    '';
    # /etc is mostly generated from this repo, so backing it up wholesale
    # would just capture build output. The exceptions are the few imperative
    # files below: the SSH host keys (also the sops decryption key for this
    # machine) and NetworkManager's saved connections (WiFi passwords,
    # imported VPN configs).
    paths = [
      "/.snapshots/restic-home"
      "/etc/ssh"
      "/etc/NetworkManager/system-connections"
    ];
    backupCleanupCommand = ''
      ${pkgs.btrfs-progs}/bin/btrfs subvolume delete /.snapshots/restic-home
    '';

    extraBackupArgs = [
      "--exclude-caches" # skips anything with a CACHEDIR.TAG (cargo, etc.)
      "--exclude-if-present"
      ".nobackup" # skips any dir containing this marker file
    ];

    exclude = [
      "/.snapshots/restic-home/**/.git/annex/objects"
      "/.snapshots/restic-home/xentac/.cache"
      "/.snapshots/restic-home/xentac/.npm"
      "/.snapshots/restic-home/xentac/go"
      "/.snapshots/restic-home/xentac/.local/share/Steam"
      "/.snapshots/restic-home/xentac/.local/share/Trash"
    ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true; # run at next boot if the laptop was off at the time
    };
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 6"
    ];
    inhibitsSleep = true; # don't suspend mid-backup
  };
}
