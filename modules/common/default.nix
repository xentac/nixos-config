# modules/common/default.nix — aggregator for modules every host imports.
{
  imports = [
    ./nix-settings.nix
    ./networking.nix
    ./users.nix
    ./shell.nix
    ./secrets.nix
  ];
}
