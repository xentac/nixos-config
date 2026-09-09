# Your user account. The password is imperative state, set with `passwd`.
{ pkgs, ... }:
{
  users.users.xentac = {
    isNormalUser = true;
    description = "Jason Chu";
    shell = pkgs.zsh;
    extraGroups = [
      "wheel" # sudo
      "networkmanager"
      "video" # brightnessctl
      "audio"
      "dialout" # serial devices (OpenCPN, NMEA, Arduino)
      "kvm"
      "libvirtd"
      "docker"
      "wireshark"
      "scanner"
      "lp"
      "input"
    ];
    # No key here on purpose: ssh comes in over tailscale and
    # ~/.ssh/authorized_keys is chezmoi-managed.
  };

  programs.bash.completion.enable = true; # system-wide bash-completion
  security.sudo.wheelNeedsPassword = true;
}
