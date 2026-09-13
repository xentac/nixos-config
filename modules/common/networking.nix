# Remote access shared by every host: firewall, tailscale, SSH.
# Desktop-only networking (NetworkManager, mDNS, GUI tools) lives in
# modules/desktop/networking.nix.
{ ... }:
{
  networking.firewall.enable = true;

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
