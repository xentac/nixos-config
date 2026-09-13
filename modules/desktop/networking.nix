# Laptop networking: Wi-Fi, VPN, file sharing, network tools.
# The parts every host needs (firewall, tailscale, SSH) are in
# modules/common/networking.nix.
{ pkgs, ... }:
{
  networking.networkmanager.enable = true;

  # Wireshark needs a setuid dumpcap + the `wireshark` group (see user-groups.nix).
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
