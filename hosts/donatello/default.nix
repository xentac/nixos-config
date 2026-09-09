# hosts/donatello/default.nix — everything specific to THIS machine.
# Shared, reusable settings live in ../../modules/nixos and are imported here.
{ inputs, pkgs, ... }:
{
  imports = [
    # Framework Laptop 13 Pro, AMD Ryzen AI 300 mainboard. (The Intel Core
    # Ultra Series 3 board would use framework-intel-core-ultra-series3 and
    # kvm-intel / hardware.cpu.intel in hardware-configuration.nix.)
    inputs.nixos-hardware.nixosModules.framework-amd-ai-300-series

    # Generated on the new machine by `nixos-generate-config`; the file
    # checked in here is a STUB. See README "Install walkthrough".
    ./hardware-configuration.nix

    # All the reusable modules (each one is a small, commented file).
    ../../modules/nixos
  ];

  networking.hostName = "donatello";

  # Brand-new silicon wants the newest kernel. nixos-hardware may also set
  # this; `lib.mkForce` isn't needed since we agree.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Hibernate support: the (encrypted) swap device from hardware-configuration.nix.
  # Uncomment once swap exists and is >= RAM.
  # boot.resumeDevice = "/dev/mapper/cryptswap";

  # DO NOT bump this after install. It records which NixOS release first
  # created stateful data (DB formats, etc.) and is not "the version you run".
  system.stateVersion = "26.05";
}
