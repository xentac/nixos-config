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
# name "grafana".
{ config, pkgs, ... }:
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
      # Served as http://grafana on the tailnet (caddy.nix); Grafana wants
      # to know its public name for redirects/cookies.
      domain = "grafana";
      root_url = "http://grafana/";
    };
    settings.security.secret_key = "$__file{${config.sops.secrets."grafana/secret_key".path}}";
    declarativePlugins = [
      (pkgs.grafanaPlugins.grafanaPlugin {
        pname = "victoriametrics-logs-datasource";
        version = "0.32.0";
        zipHash = "sha256-ggTQl7F/U7HDpxdhBHc0t5gL2YNxDGz8742Tir5e7vA=";
      })
    ];
    provision.datasources.settings.datasources = [
      {
        name = "VictoriaMetrics";
        type = "prometheus";
        url = "http://${config.services.victoriametrics.listenAddress}";
        isDefault = true;
      }
      {
        name = "VictoriaLogs";
        type = "victoriametrics-logs-datasource";
        url = "http://${config.services.victorialogs.listenAddress}";
      }
    ];
  };
}
