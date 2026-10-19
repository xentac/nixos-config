# modules/server/default.nix — aggregator for the boat-services host.
{
  imports = [
    ./media.nix
    ./whisparr.nix
    ./config-history.nix
    ./mounts.nix
    ./caddy.nix
    ./monitoring.nix
    ./backups.nix
    ./fava.nix
    ./signalk.nix
    ./lubelogger.nix
    ./calibre-web.nix
    ./paperless.nix
  ];
}
