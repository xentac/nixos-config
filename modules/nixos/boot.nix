# Bootloader and early boot.
{ ... }:
{
  # systemd-boot is simpler than GRUB on UEFI and shows every NixOS
  # generation as a boot entry (that's your rollback UI).
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 20;
  boot.loader.efi.canTouchEfiVariables = true;

  # systemd-based initrd: nicer LUKS prompt, needed for some hibernate setups.
  boot.initrd.systemd.enable = true;

  boot.supportedFilesystems = [
    "btrfs"
    "exfat"
    "ntfs"
  ];
  boot.tmp.cleanOnBoot = true;

  # Quiet boot with a splash (you had `quiet splash` on Ubuntu).
  boot.plymouth.enable = true;
  boot.kernelParams = [ "quiet" ];
}
