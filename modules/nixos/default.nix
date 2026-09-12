# modules/nixos/default.nix — aggregator. Importing this directory imports
# every module listed. Comment a line out to drop that whole area.
{
  imports = [
    ./nix-settings.nix
    ./boot.nix
    ./locale-keyboard.nix
    ./networking.nix
    ./desktop.nix
    ./audio.nix
    ./hardware-extras.nix
    ./virtualisation.nix
    ./development.nix
    ./fonts.nix
    ./users.nix
    ./shell.nix
    ./apps.nix
    ./gaming.nix
    ./backups.nix
    ./monitoring.nix
  ];
}
