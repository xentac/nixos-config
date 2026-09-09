# Snapshots (btrbk) and offsite backups (restic). Your Ubuntu box runs
# btrbk.timer daily and resticprofile timers; the restic profiles were
# root-only so they could not be read — fill in the TODOs.
{ ... }:
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

  # Offsite: uncomment and fill in once you've decided on the repo.
  # Password goes in /etc/restic/password (chmod 600), NOT in this repo.
  # services.restic.backups.home = {
  #   repository = "TODO e.g. sftp:user@host:/backups/framework or b2:bucket:path";
  #   passwordFile = "/etc/restic/password";
  #   paths = [ "/home/xentac" ];
  #   exclude = [ "/home/xentac/.cache" "/home/xentac/.local/share/Steam" ];
  #   timerConfig = { OnCalendar = "daily"; Persistent = true; };
  #   pruneOpts = [ "--keep-daily 7" "--keep-weekly 4" "--keep-monthly 6" ];
  # };
}
