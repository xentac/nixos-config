# Desktop-only group memberships for the user; the groups themselves are
# created by the modules that need them (virtualisation.nix -> docker/libvirtd,
# networking.nix -> networkmanager/wireshark, ...). Base account: common/users.nix.
{ ... }:
{
  users.users.xentac.extraGroups = [
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
}
