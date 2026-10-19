# The naming layer: one Caddy process with the caddy-tailscale plugin
# (docs/adr/0003). Each published service gets its OWN tailnet hostname via
# an embedded tsnet node — the declarative successor to tsdproxy's docker
# labels. Adding a service = one line in `published` below.
#
# stash and the whisparrs appear ONLY here (they bind 127.0.0.1): reaching them
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
    whisparr-scenes = "127.0.0.1:6969"; # whisparr.nix
    whisparr-movies = "127.0.0.1:6970"; # whisparr.nix
    stash = "127.0.0.1:9999";
    alba-grafana = "127.0.0.1:${toString config.services.grafana.settings.server.http_port}";
    fava = "127.0.0.1:5000"; # fava.nix; finances — restrict the node in the tailnet ACL
    lubelogger = "127.0.0.1:${toString config.services.lubelogger.port}"; # lubelogger.nix; restrict the node in the tailnet ACL
    calibre-web = "127.0.0.1:${toString config.services.calibre-web.listen.port}"; # calibre-web.nix
    paperless = "127.0.0.1:${toString config.services.paperless.port}"; # paperless.nix; restrict the node in the tailnet ACL
    signalk = "127.0.0.1:${toString config.alba.signalk.port}"; # signalk.nix; also open on the LAN for boat apps
    # The Signal K built into the Victron GX (Venus OS): signalk's only
    # data source. An appliance with a DHCP-ish address — update here
    # when it moves. Its name used to be `signalk` on tsdproxy.
    victron-signalk = "192.168.1.207:3000";
  };

  # Machines allowed to push metrics (alba-metrics-push below): name ->
  # tailnet IPs (`tailscale ip`). The name becomes the `instance` label.
  metricsPushers = {
    donatello = [
      "100.112.212.94"
      "fd7a:115c:a1e0::3939:d45f"
    ];
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
    virtualHosts =
      lib.mapAttrs' (name: backend: {
        name = "https://${name}.${tailnetDomain}";
        value = {
          extraConfig = ''
            bind tailscale/${name}
            reverse_proxy ${backend}
          '';
        };
      }) published
      // {
        # Push endpoint into alba-nix's VictoriaMetrics for machines that
        # can't or shouldn't be scraped (donatello's restic metrics, on a
        # timer: modules/desktop/monitoring.nix). Not a `published` entry:
        # that would put the whole VictoriaMetrics API, deletes included,
        # on the tailnet. Only Prometheus-text imports are proxied, and
        # only from the tailnet IPs in metricsPushers. The client picks
        # `job` (?job=...); `instance` comes from its IP. The query string
        # is rebuilt from just those two, and VictoriaMetrics' extra_label
        # overrides labels in the pushed lines, so a pusher can only ever
        # write series as itself.
        "https://alba-metrics-push.${tailnetDomain}".extraConfig = ''
          bind tailscale/alba-metrics-push
          map {remote_host} {push_instance} {
            ${lib.concatStrings (
              lib.mapAttrsToList (name: ips: lib.concatMapStrings (ip: "${ip} ${name}\n") ips) metricsPushers
            )}
            default -
          }
          @push {
            path /api/v1/import/prometheus
            not vars {push_instance} -
          }
          handle @push {
            rewrite * ?extra_label=job={query.job}&extra_label=instance={push_instance}
            reverse_proxy ${config.services.victoriametrics.listenAddress}
          }
          handle {
            respond 403
          }
        '';
      };
  };

  systemd.services.caddy.serviceConfig.EnvironmentFile = config.sops.secrets."caddy/environment".path;

  # The plugin build on PATH, for `caddy validate`, `caddy list-modules`, etc.
  environment.systemPackages = [ config.services.caddy.package ];
}
