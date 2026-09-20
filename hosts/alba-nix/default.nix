# hosts/alba-nix/default.nix — the boat-services VM on Alba's Proxmox.
# Starts as the media-automation host (sabnzbd + arrs + stash) and will
# eventually absorb the services on the Ubuntu docker VM. Design decisions
# are recorded in docs/adr/; day-to-day operations in docs/alba-nix.md.
{ inputs, ... }:
{
  imports = [
    inputs.disko.nixosModules.disko
    ./disko.nix # partition layout; replaces hardware-configuration.nix

    ../../modules/common
    ../../modules/server
  ];

  networking.hostName = "alba-nix";

  # Which encrypted file sops.secrets.* names refer to for this host.
  sops.defaultSopsFile = ../../secrets/alba-nix.yaml;

  # Static LAN address: the boat's router being down must not keep this VM
  # from booting into a working state (SMB mounts, tailscale, monitoring).
  networking.useDHCP = false;
  networking.useNetworkd = true;
  systemd.network.networks."10-lan" = {
    # Proxmox virtio NIC; "en*" matches whatever slot name it gets (ens18).
    matchConfig.Name = "en*";
    address = [ "192.168.1.23/24" ];
    routes = [ { Gateway = "192.168.1.1"; } ];
    dns = [ "192.168.1.1" ];
  };

  # Allow UDP ports for mosh
  networking.firewall.allowedUDPPortRanges = [
    {
      from = 61010;
      to = 61019;
    }
  ];

  # UEFI boot off the ESP disko creates; every generation in the boot menu
  # is the remote-rollback safety net, so keep plenty.
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 30;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.systemd.enable = true;
  # Virtio drivers so the initrd can find the disk and NIC under QEMU.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
    "virtio_net"
  ];

  # Guest agent: lets Proxmox see the IP, shut down cleanly, and snapshot
  # with quiesce.
  services.qemuGuest.enable = true;

  # Unlike the laptop (where authorized_keys is chezmoi-managed and the
  # password is set interactively at the console), a headless server must
  # bake its access path into the image: with no password, key-only sshd,
  # and no chezmoi, a fresh install would otherwise be unreachable.
  # Root access is what `just deploy alba-nix` (deploy-rs) and
  # nixos-anywhere use.
  users.users.xentac.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMpYxRf08tuKPVgsBua3etm5rOHj/I2XL6g8Gj4Ra3mT xentac@baxter"
  ];
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMpYxRf08tuKPVgsBua3etm5rOHj/I2XL6g8Gj4Ra3mT xentac@baxter"
  ];

  # DO NOT bump this after install. It records which NixOS release first
  # created stateful data (DB formats, etc.) and is not "the version you run".
  system.stateVersion = "26.05";
}
