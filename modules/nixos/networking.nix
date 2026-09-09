# Wi-Fi, VPN, SSH, remote access, file sharing.
{ pkgs, ... }:
{
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

  # Tailscale (you're already on a tailnet as "baxter"). After install:
  #   sudo tailscale up
  services.tailscale.enable = true;
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  # Tailscale's own checks want this for exit nodes/subnet routes.
  networking.firewall.checkReversePath = "loose";

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
  programs.mosh.enable = true;

  # Wireshark needs a setuid dumpcap + the `wireshark` group (see users.nix).
  programs.wireshark = {
    enable = true;
    package = pkgs.wireshark; # GUI build; pkgs.wireshark-cli for tshark only
  };

  # mDNS: discovers driverless printers and .local hosts.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # Samba/Windows shares from Thunar and the CLI. Server side (smbd) is off;
  # enable services.samba if you actually share from this laptop.
  services.gvfs.enable = true; # smb://, sftp://, mtp:// in Thunar
  environment.systemPackages = with pkgs; [
    cifs-utils
    samba # smbclient
    wireguard-tools # NordVPN: import WG configs into NetworkManager
    nmap
    whois
    socat
    sshfs
    iftop
    net-tools
    inetutils
  ];
}
