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
    alba-grafana = "127.0.0.1:3000";
  };
in
{
  # TS_AUTHKEY=<tailscale auth key or OAuth client secret> — used by tsnet
  # to register the nodes on first start; state persists in
  # /var/lib/caddy/tailscale afterwards.
  sops.secrets."caddy/environment" = { };

  services.caddy = {
    enable = true;
    # Default is `level ERROR`, which swallows all tsnet node
    # registration/auth output. DEBUG while the tailscale layer is young.
    logFormat = "level DEBUG";
    # Caddy with plugins is rebuilt from source with the plugin vendored in;
    # the hash pins the combined go modules. Bump the date-commit
    # pseudo-version to update the plugin (github.com/tailscale/caddy-tailscale).
    # Must be >= 2025-11-17 (PR #116): older plugin builds vendor a tsnet
    # that can't exchange OAuth client secrets for auth keys ("invalid
    # key: unable to validate API key").
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/tailscale/caddy-tailscale@v0.0.0-20260826180304-de41b249af4f" ];
      hash = "sha256-IzLM8Qgxurrgs6NBygGEGyzXQUxQMPP3Y6iIWVN5ZvQ=";
    };

    globalConfig = ''
      tailscale {
        auth_key {env.TS_AUTHKEY}
        state_dir /var/lib/caddy/tailscale
        # OAuth-registered nodes must advertise the tag(s) the OAuth
        # client was created with.
        tags tag:caddy
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

  systemd.services.caddy = {
    serviceConfig.EnvironmentFile = config.sops.secrets."caddy/environment".path;
    # The NixOS module reloads caddy on config-only changes, but
    # caddy-tailscale doesn't survive graceful reloads (the old config's
    # tsnet listeners stay bound and the reload fails). Restart instead.
    reloadTriggers = lib.mkForce [ ];
  };
}
