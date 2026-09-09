# Steam. programs.steam handles the 32-bit libs, firewall for Remote Play, etc.
{ ... }:
{
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
  };
  programs.gamemode.enable = true;
  hardware.graphics.enable32Bit = true;
}
