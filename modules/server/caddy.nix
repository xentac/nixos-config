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
  tailnetDomain = "stalk-darter.ts.net";
  # tailnet-name -> backend. "host:port" works for cross-host backends
  # too (victron-signalk is one).
  published = {
    sonarr = "127.0.0.1:8989";
    radarr = "127.0.0.1:7878";
    sabnzbd = "127.0.0.1:8080";
    whisparr = "127.0.0.1:6969";
    stash = "127.0.0.1:9999";
    alba-grafana = "127.0.0.1:${toString config.services.grafana.settings.server.http_port}";
    fava = "127.0.0.1:5000"; # fava.nix; finances — restrict the node in the tailnet ACL
    lubelogger = "127.0.0.1:${toString config.services.lubelogger.port}"; # lubelogger.nix; restrict the node in the tailnet ACL
    calibre-web = "127.0.0.1:${toString config.services.calibre-web.listen.port}"; # calibre-web.nix
    signalk = "127.0.0.1:3000"; # signalk.nix; also open on the LAN for boat apps
    # The Signal K built into the Victron GX (Venus OS): signalk's only
    # data source. An appliance with a DHCP-ish address — update here
    # when it moves. Its name used to be `signalk` on tsdproxy.
    victron-signalk = "192.168.1.207:3000";
  };
in
{
  # TS_AUTHKEY=<tailscale auth key or OAuth client secret> — used by tsnet
  # to register the nodes on first start; state persists in
  # /var/lib/caddy/tailscale afterwards.
  sops.secrets."caddy/environment" = { };

  services.caddy = {
    enable = true;
    # The NixOS module reloads caddy on config-only changes by default,
    # but caddy-tailscale doesn't survive graceful reloads (the old
    # config's tsnet listeners stay bound and the reload fails). false
    # swaps the reload trigger for a restart trigger on the Caddyfile.
    # (Merely emptying reloadTriggers is not enough: the Caddyfile lives
    # at a fixed /etc path, so without a trigger a new `published` entry
    # changes nothing in the unit and caddy keeps running the old config.)
    enableReload = false;
    # Default is `level ERROR`, which swallows all tsnet node
    # registration/auth output.
    logFormat = "level INFO";
    # Caddy with plugins is rebuilt from source with the plugin vendored in;
    # the hash pins the combined go modules. Bump the date-commit
    # pseudo-version to update the plugin (github.com/tailscale/caddy-tailscale).
    # Must be >= 2025-11-17 (PR #116): older plugin builds vendor a tsnet
    # that can't exchange OAuth client secrets for auth keys ("invalid
    # key: unable to validate API key").
    # The hash also changes whenever nixpkgs bumps caddy itself (it covers
    # caddy's own go.sum too) — a flake-lock update can invalidate it.
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/tailscale/caddy-tailscale@v0.0.0-20260826180304-de41b249af4f" ];
      hash = "sha256-OzzyBF/SA1WkX/g+WOwvZo2t5bfeNPOeYJ1ziOLlTTk=";
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
    # The full ts.net site address does double duty: it matches the Host
    # header clients actually send (a bare "radarr" address would not),
    # and it makes Caddy fetch the node's HTTPS cert from Tailscale
    # automatically. http:// requests get Caddy's standard redirect to
    # https. Requires MagicDNS + HTTPS Certificates enabled on the
    # tailnet (they are).
    virtualHosts = lib.mapAttrs' (name: backend: {
      name = "https://${name}.${tailnetDomain}";
      value = {
        extraConfig = ''
          bind tailscale/${name}
          reverse_proxy ${backend}
        '';
      };
    }) published;
  };

  systemd.services.caddy.serviceConfig.EnvironmentFile = config.sops.secrets."caddy/environment".path;

  # The plugin build on PATH, for `caddy validate`, `caddy list-modules`, etc.
  environment.systemPackages = [ config.services.caddy.package ];
}
