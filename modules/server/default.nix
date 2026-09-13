# modules/server/default.nix — aggregator for the boat-services host.
{
  imports = [
    ./media.nix
    ./mounts.nix
    ./caddy.nix
    ./monitoring.nix
    ./backups.nix
  ];
}
