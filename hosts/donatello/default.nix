# hosts/donatello/default.nix — everything specific to THIS machine.
# Shared, reusable settings live in ../../modules/nixos and are imported here.
{ inputs, pkgs, ... }:
{
  imports = [
    # Framework Laptop 13 Pro, AMD Ryzen AI 300 mainboard. (The Intel Core
    # Ultra Series 3 board would use framework-intel-core-ultra-series3 and
    # kvm-intel / hardware.cpu.intel in hardware-configuration.nix.)
    inputs.nixos-hardware.nixosModules.framework-amd-ai-300-series

    # `nixos-generate-config` output synced from the booted machine, plus
    # the btrfs mount options the generator drops. See docs/install.md.
    ./hardware-configuration.nix

    # All the reusable modules (each one is a small, commented file).
    ../../modules/nixos
  ];

  networking.hostName = "donatello";

  # Brand-new silicon wants the newest kernel. nixos-hardware may also set
  # this; `lib.mkForce` isn't needed since we agree.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Hibernate into the encrypted swap device (64 GB, = RAM) from
  # hardware-configuration.nix. This becomes a `resume=` kernel parameter, so
  # it takes effect on the next BOOT, not on switch. NOT YET TESTED: reboot,
  # then try `systemctl hibernate` at the laptop (expect full power-off,
  # then resume through the LUKS unlock with the session intact).
  boot.resumeDevice = "/dev/mapper/cryptswap";

  # Unlock LUKS from the TPM at boot (no passphrase prompt). Harmless until a
  # key is enrolled — it falls back to the passphrase. Enroll once per device:
  #   sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-uuid/<uuid>
  # (UUIDs are in hardware-configuration.nix; the passphrase stays as fallback.
  # PCR 7 = Secure Boot state, so kernel/BIOS updates don't force re-enrolling.)
  boot.initrd.luks.devices."cryptroot".crypttabExtraOpts = [ "tpm2-device=auto" ];
  boot.initrd.luks.devices."cryptswap".crypttabExtraOpts = [ "tpm2-device=auto" ];

  # DO NOT bump this after install. It records which NixOS release first
  # created stateful data (DB formats, etc.) and is not "the version you run".
  system.stateVersion = "26.05";
}
