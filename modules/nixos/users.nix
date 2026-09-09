# Your user account. Set the password on first boot with `passwd`
# (or set users.users.xentac.hashedPassword from `mkpasswd`).
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
      "plugdev"
      "kvm"
      "libvirtd"
      "docker"
      "wireshark"
      "scanner"
      "lp"
      "input"
    ];
    # Drop your public key here so ssh works before you've copied dotfiles:
    # openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... jchu@xentac.net" ];
  };

  programs.bash.completion.enable = true; # system-wide bash-completion
  security.sudo.wheelNeedsPassword = true;
}
