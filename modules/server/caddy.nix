# The naming layer: one Caddy process with the caddy-tailscale plugin
# (docs/adr/0003). Each published service gets its OWN tailnet hostname via
# an embedded tsnet node — the declarative successor to tsdproxy's docker
# labels. Adding a service = one line in `published` below.
#
# stash and whisparr appear ONLY here (they bind 127.0.0.1): reaching them
# requires the tailnet, and the tailnet ACL denies kid devices those nodes
# (kid-proofing layer 3). tsnet nodes are location-independent, so this
# Caddy can also front cross-host backends later (e.g. services still on
# the docker VM) by pointing an entry at another machine's address.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # tailnet-name -> backend. All local today; "host:port" works for
  # cross-host backends too.
  published = {
    sonarr = "127.0.0.1:8989";
    radarr = "127.0.0.1:7878";
    sabnzbd = "127.0.0.1:8080";
    whisparr = "127.0.0.1:6969";
    stash = "127.0.0.1:9999";
    grafana = "127.0.0.1:3000";
  };
in
{
  # TS_AUTHKEY=<tailscale auth key or OAuth client secret> — used by tsnet
  # to register the nodes on first start; state persists in
  # /var/lib/caddy/tailscale afterwards.
  sops.secrets."caddy/environment" = { };

  services.caddy = {
    enable = true;
    # Caddy with plugins is rebuilt from source with the plugin vendored in;
    # the hash pins the combined go modules. Bump the date-commit
    # pseudo-version to update the plugin (github.com/tailscale/caddy-tailscale).
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/tailscale/caddy-tailscale@v0.0.0-20250207163903-69a970c84556" ];
      hash = "sha256-2EOTu6CIRykdg4SsTsBtHx3/aNrRLQG9O9UHK4plsaI=";
    };

    globalConfig = ''
      tailscale {
        auth_key {env.TS_AUTHKEY}
        state_dir /var/lib/caddy/tailscale
      }
    '';

    # One virtual host per published name, listening on its tsnet node.
    # Plain HTTP: traffic only ever crosses the tailnet (wireguard), and
    # skipping TLS keeps the tsnet nodes free of cert plumbing for now.
    virtualHosts = lib.mapAttrs' (name: backend: {
      name = "http://${name}";
      value = {
        extraConfig = ''
          bind tailscale/${name}
          reverse_proxy ${backend}
        '';
      };
    }) published;
  };

  systemd.services.caddy.serviceConfig.EnvironmentFile = config.sops.secrets."caddy/environment".path;
}
