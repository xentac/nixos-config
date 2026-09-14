# Remote access shared by every host: firewall, tailscale, SSH.
# Desktop-only networking (NetworkManager, mDNS, GUI tools) lives in
# modules/desktop/networking.nix.
{ pkgs, ... }:
{
  networking.firewall.enable = true;

  # Network debugging kit — wanted exactly when a box is misbehaving, so
  # it lives on every host rather than a nix-shell away. (ss/ip from
  # iproute2 are in the NixOS base already.)
  environment.systemPackages = with pkgs; [
    net-tools # netstat, ifconfig, route
    inetutils # telnet, ftp, traceroute
    dig
    curl
    tcpdump
    nmap
    mtr
    whois
    socat
    iftop
    lsof
  ];

  # Every machine joins the tailnet; `sudo tailscale up` once after install.
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
}
