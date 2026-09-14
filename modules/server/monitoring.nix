# alba-nix monitors itself: exporters -> VictoriaMetrics -> Grafana, plus
# journald -> VictoriaLogs. Same shape as the laptop's stack
# (modules/desktop/monitoring.nix) minus the hardware-specific bits, and
# this host is the future hub: other boat hosts will eventually ship their
# metrics/logs here. Donatello stays separate on purpose.
#
# TSDB data lives on the LOCAL disk (/var/lib), NOT on vault — the monitor
# must keep recording while the NAS is down, and restic->B2 already covers
# durability (docs/adr/0004).
#
# Everything binds localhost; caddy.nix publishes Grafana as the tailnet
# name "alba-grafana".
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # nixpkgs stamps buildinfo.Version with the bare version ("1.126.0"),
  # but upstream release builds use "victoria-metrics-…-tags-v1.126.0".
  # The stock dashboards' job/version template variables filter on that
  # prefix (version=~"victoria-metrics-.*"), so with a nixpkgs build
  # every panel shows No Data. Restamp the upstream format. Tests are
  # skipped: one asserts buildinfo.Version is unset, and the package's
  # preCheck workaround only knows the bare-version form.
  restampVersion =
    pkg: productPrefix:
    pkg.overrideAttrs (old: {
      ldflags = map (
        f:
        if lib.hasInfix "buildinfo.Version=" f then
          "-X github.com/VictoriaMetrics/VictoriaMetrics/lib/buildinfo.Version=${productPrefix}-tags-v${old.version}"
        else
          f
      ) old.ldflags;
      doCheck = false;
    });

  # Dashboards from grafana.com, pinned by (id, revision, hash) — the
  # declarative replacement for importing by hand. Revisions are
  # immutable, so the fetch is reproducible. Most dashboards pick their
  # datasource via a template variable (defaulting to the default
  # datasource); the jq pass hard-wires the ones that instead declare a
  # `__inputs` placeholder, pointing prometheus-type inputs at our
  # VictoriaMetrics datasource uid.
  grafanaDashboard =
    {
      id,
      rev,
      hash,
    }:
    pkgs.runCommand "grafana-dashboard-${toString id}-rev${toString rev}.json"
      {
        src = pkgs.fetchurl {
          url = "https://grafana.com/api/dashboards/${toString id}/revisions/${toString rev}/download";
          inherit hash;
        };
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        jq 'reduce (.__inputs // [])[] as $i (.;
              if $i.pluginId == "prometheus"
              then walk(if . == ("''${" + $i.name + "}") then "victoriametrics" else . end)
              else . end)
            | del(.__inputs)' "$src" > "$out"
      '';

  dashboardsDir = pkgs.linkFarm "grafana-dashboards" [
    {
      name = "node-exporter-full.json";
      path = grafanaDashboard {
        id = 1860;
        rev = 45;
        hash = "sha256-GExrdAnzBtp1Ul13cvcZRbEM6iOtFrXXjEaY6g6lGYY=";
      };
    }
    {
      name = "victoriametrics-single-node.json";
      path = grafanaDashboard {
        id = 10229;
        rev = 58;
        hash = "sha256-ohLgCHAdCSV9b3YkRAPPqCGOZaMKg1VzQK9dHlm9HAM=";
      };
    }
    {
      name = "victorialogs-single-node.json";
      path = grafanaDashboard {
        id = 22084;
        rev = 11;
        hash = "sha256-XCS5f54tPxc8t9ppEX0ahzw8ufex6K3MIBbDL6tMoIY=";
      };
    }
    {
      name = "restic-exporter.json";
      path = grafanaDashboard {
        id = 17554;
        rev = 3;
        hash = "sha256-jMv2ag4DlA4Bx+szNFEVF+WrBipICMx1D9uy/oD5Blw=";
      };
    }
  ];
in
{
  # Kernel/system metrics on 127.0.0.1:9100.
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "127.0.0.1";
    enabledCollectors = [ "systemd" ]; # per-unit metrics: failed services etc.
  };

  # Backup metrics (snapshot count, age of newest snapshot, repo size) —
  # alerts on "backups silently stopped". Reuses the repo/credentials from
  # backups.nix. Long refresh: each one costs B2 API calls.
  services.prometheus.exporters.restic = {
    enable = true;
    listenAddress = "127.0.0.1";
    inherit (config.services.restic.backups.state) repository passwordFile environmentFile;
    refreshInterval = 3600;
  };

  # Time-series database. When adding an exporter, add a scrape_configs
  # entry pointing at it.
  services.victoriametrics = {
    enable = true;
    package = restampVersion pkgs.victoriametrics "victoria-metrics";
    listenAddress = "127.0.0.1:8428";
    retentionPeriod = "1y";
    prometheusConfig = {
      global.scrape_interval = "15s";
      scrape_configs = [
        {
          job_name = "node";
          static_configs = [
            {
              targets = [
                "127.0.0.1:${toString config.services.prometheus.exporters.node.port}"
              ];
            }
          ];
        }
        {
          job_name = "restic";
          static_configs = [
            {
              targets = [
                "127.0.0.1:${toString config.services.prometheus.exporters.restic.port}"
              ];
            }
          ];
        }
        {
          job_name = "victoriametrics";
          static_configs = [
            { targets = [ config.services.victoriametrics.listenAddress ]; }
          ];
        }
        {
          job_name = "victorialogs";
          static_configs = [
            { targets = [ config.services.victorialogs.listenAddress ]; }
          ];
        }
      ];
    };
  };

  # Log database; journald ships into it below.
  services.victorialogs = {
    enable = true;
    package = restampVersion pkgs.victorialogs "victoria-logs";
    listenAddress = "127.0.0.1:9428";
    extraOptions = [ "-retentionPeriod=1y" ];
  };

  services.journald.upload = {
    enable = true;
    settings.Upload.URL = "http://127.0.0.1:9428/insert/journald";
  };

  # VictoriaLogs is the long-term store; journald is just a recent buffer.
  services.journald.extraConfig = ''
    SystemMaxUse=500M
  '';

  sops.secrets."grafana/secret_key".owner = "grafana";

  services.grafana = {
    enable = true;
    settings.server = {
      http_addr = "127.0.0.1";
      http_port = 3000;
      # Served via caddy.nix on the tailnet; Grafana wants to know its
      # public name for redirects/cookies.
      domain = "alba-grafana.stalk-darter.ts.net";
      root_url = "https://alba-grafana.stalk-darter.ts.net/";
    };
    settings.security.secret_key = "$__file{${config.sops.secrets."grafana/secret_key".path}}";
    declarativePlugins = [
      (pkgs.grafanaPlugins.grafanaPlugin {
        pname = "victoriametrics-logs-datasource";
        version = "0.32.0";
        zipHash = "sha256-ggTQl7F/U7HDpxdhBHc0t5gL2YNxDGz8742Tir5e7vA=";
      })
    ];
    # Datasources are matched by name, but pre-uid records in grafana's DB
    # carry auto-generated uids, and updating a datasource to a new uid
    # fails ("data source not found"). Deleting by name first makes each
    # startup recreate them cleanly with the uids below.
    provision.datasources.settings.deleteDatasources = [
      {
        name = "VictoriaMetrics";
        orgId = 1;
      }
      {
        name = "VictoriaLogs";
        orgId = 1;
      }
    ];
    provision.datasources.settings.datasources = [
      {
        name = "VictoriaMetrics";
        # Fixed uid so provisioned dashboards can reference it.
        uid = "victoriametrics";
        type = "prometheus";
        url = "http://${config.services.victoriametrics.listenAddress}";
        isDefault = true;
      }
      {
        name = "VictoriaLogs";
        uid = "victorialogs";
        type = "victoriametrics-logs-datasource";
        url = "http://${config.services.victorialogs.listenAddress}";
      }
    ];
    provision.dashboards.settings.providers = [
      {
        name = "declarative";
        options.path = dashboardsDir;
      }
    ];
  };
}
