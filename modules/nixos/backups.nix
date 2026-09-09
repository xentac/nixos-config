# Snapshots (btrbk) and offsite backups (restic). Your Ubuntu box runs
# btrbk.timer daily and resticprofile timers; the restic profiles were
# root-only so they could not be read — fill in the TODOs.
{ pkgs, ... }:
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
  # on Ubuntu). Uncomment once the system is running and you've picked a
  # repository. Password goes in /etc/restic/password (chmod 600), NOT here.
  #
  # Paths inside the repo are prefixed /.snapshots/restic-home instead of
  # /home; restore with e.g.
  #   sudo restic-home restore latest --target /tmp/r \
  #        --include /.snapshots/restic-home/xentac/Documents
  # (`restic-home` is a wrapper the module generates with repo + password set.)
  #
  # services.restic.backups.home = {
  #   repository = "TODO e.g. sftp:user@host:/backups/donatello or b2:bucket:path";
  #   passwordFile = "/etc/restic/password";
  #   initialize = true; # create the repo on first run if it doesn't exist
  #
  #   # Read-only snapshot at a FIXED path so restic's parent-snapshot
  #   # matching and dedup keep working run to run. The delete first handles
  #   # a previous run that died before cleanup.
  #   backupPrepareCommand = ''
  #     ${pkgs.btrfs-progs}/bin/btrfs subvolume delete /.snapshots/restic-home 2>/dev/null || true
  #     ${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot -r /home /.snapshots/restic-home
  #   '';
  #   paths = [ "/.snapshots/restic-home" ];
  #   backupCleanupCommand = ''
  #     ${pkgs.btrfs-progs}/bin/btrfs subvolume delete /.snapshots/restic-home
  #   '';
  #
  #   exclude = [
  #     "/.snapshots/restic-home/xentac/.cache"
  #     "/.snapshots/restic-home/xentac/.local/share/Steam"
  #     "/.snapshots/restic-home/xentac/.local/share/Trash"
  #   ];
  #   timerConfig = {
  #     OnCalendar = "daily";
  #     Persistent = true; # run at next boot if the laptop was off at the time
  #   };
  #   pruneOpts = [
  #     "--keep-daily 7"
  #     "--keep-weekly 4"
  #     "--keep-monthly 6"
  #   ];
  #   inhibitsSleep = true; # don't suspend mid-backup
  # };
}
