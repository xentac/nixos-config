# Declarative partition layout, applied by nixos-anywhere at install time
# (and never again — disko only formats, it doesn't migrate). Also generates
# the fileSystems.* entries, so there is no hardware-configuration.nix.
{ ... }:
let
  # Mount options shared by every btrfs subvolume. zstd:1 = cheap
  # compression, right for a VM disk backed by an LVM-thin pool.
  btrfsOpts = [
    "compress=zstd:1"
    "noatime"
  ];
in
{
  disko.devices.disk.main = {
    type = "disk";
    # The VM's single virtio-scsi disk (200 GB thin-provisioned on the
    # Proxmox side). virtio-scsi appears as /dev/sda; if the VM is created
    # with virtio-blk instead, change to /dev/vda before installing.
    device = "/dev/sda";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = [
              "-L"
              "nixos"
              "-f"
            ];
            subvolumes = {
              # Root stays small: /var/lib (service state) and /downloads
              # are their own subvolumes so snapshots and backup excludes
              # have clean boundaries.
              "@" = {
                mountpoint = "/";
                mountOptions = btrfsOpts;
              };
              "@nix" = {
                mountpoint = "/nix";
                mountOptions = btrfsOpts;
              };
              # All service state (arr sqlite DBs, stash, Grafana, the
              # Victoria TSDBs). backups.nix snapshots THIS subvolume for
              # consistent restic runs.
              "@var-lib" = {
                mountpoint = "/var/lib";
                mountOptions = btrfsOpts;
              };
              # Download scratch: temporary by definition (a download's done
              # when it's integrated into the annex on vault), excluded from
              # backups. Compression off — it's already-compressed media.
              "@downloads" = {
                mountpoint = "/downloads";
                mountOptions = [ "noatime" ];
              };
              # Parking spot for the read-only snapshots backups.nix takes.
              "@snapshots" = {
                mountpoint = "/.snapshots";
                mountOptions = btrfsOpts;
              };
            };
          };
        };
      };
    };
  };
}
