# modules/desktop/default.nix — aggregator for laptop/desktop modules.
# Importing this directory imports every module listed. Comment a line out
# to drop that whole area.
{
  imports = [
    ./boot.nix
    ./locale-keyboard.nix
    ./networking.nix
    ./user-groups.nix
    ./desktop.nix
    ./audio.nix
    ./hardware-extras.nix
    ./virtualisation.nix
    ./development.nix
    ./fonts.nix
    ./apps.nix
    ./gaming.nix
    ./backups.nix
    ./monitoring.nix
  ];
}
