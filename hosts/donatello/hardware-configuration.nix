# hosts/framework/hardware-configuration.nix — STUB, REPLACE ME.
#
# On the new laptop, after partitioning and mounting under /mnt, run:
#     sudo nixos-generate-config --root /mnt
# and copy the generated /mnt/etc/nixos/hardware-configuration.nix over this
# file. It fills in real UUIDs, kernel modules, and CPU type.
#
# The layout below mirrors what you run today on Ubuntu (btrfs, subvolumes
# @ and @home, zstd compression) plus a @nix subvolume and LUKS. Keep the
# mount options when you paste the generated file in; nixos-generate-config
# does NOT preserve compress/noatime options.
{
  config,
  lib,
  modulesPath,
  ...
}:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "thunderbolt"
    "nvme"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # Full-disk encryption (recommended on a laptop; your Ubuntu install is
  # unencrypted). Delete this block if you decide against LUKS.
  boot.initrd.luks.devices."cryptroot".device = "/dev/disk/by-uuid/REPLACE-LUKS-ROOT-UUID";
  # Swap must be encrypted too, or hibernation writes RAM to disk in the
  # clear. The systemd initrd reuses the passphrase, so still one prompt.
  boot.initrd.luks.devices."cryptswap".device = "/dev/disk/by-uuid/REPLACE-LUKS-SWAP-UUID";

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/REPLACE-BTRFS-UUID";
    fsType = "btrfs";
    options = [
      "subvol=@"
      "compress=zstd:1"
      "noatime"
      "ssd"
      "discard=async"
      "space_cache=v2"
    ];
  };

  fileSystems."/home" = {
    device = "/dev/disk/by-uuid/REPLACE-BTRFS-UUID";
    fsType = "btrfs";
    options = [
      "subvol=@home"
      "compress=zstd:1"
      "noatime"
      "ssd"
      "discard=async"
      "space_cache=v2"
    ];
  };

  # /nix is where every package lives. A separate subvolume keeps it out of
  # your @ / @home snapshots (it is fully reproducible from this repo anyway).
  fileSystems."/nix" = {
    device = "/dev/disk/by-uuid/REPLACE-BTRFS-UUID";
    fsType = "btrfs";
    options = [
      "subvol=@nix"
      "compress=zstd:1"
      "noatime"
      "ssd"
      "discard=async"
      "space_cache=v2"
    ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/REPLACE-EFI-UUID";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  # Size >= RAM (64G) if you want hibernation; 8G otherwise.
  swapDevices = [ { device = "/dev/mapper/cryptswap"; } ];

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
