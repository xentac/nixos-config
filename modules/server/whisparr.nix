# Two Whisparr instances, one per kind of adult release (docs/adr/0006):
#
#   whisparr-scenes — v2 (Sonarr-based): a site is a series, its scenes
#                     episodes. Root folder /adult/scenes.
#   whisparr-movies — v3 (Radarr-based): full-length movies ONLY. Root
#                     folder /adult/movies. v3 can track scenes too, but
#                     adding a studio/performer here would duplicate
#                     whisparr-scenes — that's a usage rule, not enforced.
#
# nixpkgs' services.whisparr is single-instance with a fixed unit name,
# so this replaces it with the same ~unit built twice. The settings ->
# WHISPARR__* env var logic is nixpkgs' own helper, imported rather than
# copied, so upstream fixes still apply.
#
# Each instance: its own system user (primary group media for
# /downloads, plus adult for /adult — see media.nix), state in
# /var/lib/<name> (covered by backups.nix's /var/lib snapshot), UMask
# 0002 so its /downloads writes stay group-writable, and a localhost-only
# bind: caddy.nix publishes it under its tailnet name, never the LAN.
# Download clients (sab category), indexers and root folders live in
# each instance's DB, configured in the UI — see docs/alba-nix.md.
{
  lib,
  modulesPath,
  pkgs,
  ...
}:
let
  servarr = import (modulesPath + "/services/misc/servarr/settings-options.nix") {
    inherit lib pkgs;
  };

  instances = {
    whisparr-scenes = {
      package = pkgs.whisparr_2;
      port = 6969;
    };
    whisparr-movies = {
      package = pkgs.whisparr_3;
      port = 6970;
    };
  };

  mkInstance =
    name:
    { package, port }:
    let
      dataDir = "/var/lib/${name}";
      # The upstream module's option defaults, plus the bind.
      settings = {
        update.mechanism = "external";
        update.automatically = false;
        log.analyticsEnabled = false;
        server = {
          inherit port;
          bindaddress = "127.0.0.1";
        };
      };
    in
    {
      systemd.tmpfiles.rules = [ "d '${dataDir}' 0700 ${name} media - -" ];

      systemd.services.${name} = {
        description = "Whisparr (${name})";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];
        environment = servarr.mkServarrSettingsEnvVars "WHISPARR" settings;
        serviceConfig = {
          Type = "simple";
          User = name;
          Group = "media";
          UMask = "0002";
          ExecStart = "${lib.getExe package} -nobrowser -data='${dataDir}'";
          Restart = "on-failure";
        };
      };

      users.users.${name} = {
        isSystemUser = true;
        group = "media";
        extraGroups = [ "adult" ];
        home = dataDir;
      };
    };
in
{
  config = lib.mkMerge (lib.mapAttrsToList mkInstance instances);
}
