# Local monitoring stack: exporters -> VictoriaMetrics -> Grafana, plus
# journald -> VictoriaLogs -> Grafana for logs. VictoriaMetrics speaks the
# Prometheus protocol and scrapes exporters itself, so there's no separate
# Prometheus process. Everything binds to localhost only.
#
# Grafana lives at http://localhost:3000 (first login admin/admin, it
# prompts for a new password). Import dashboard ID 1860 ("Node Exporter
# Full") for a complete system overview.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Smokeping targets, IP -> display name. The IP is what gets pinged;
  # the name is what the `host` label shows in Grafana (rewritten by the
  # metric_relabel_configs in the smokeping scrape job below). Raw IPs
  # rather than DNS/MagicDNS names because the prober resolves names only
  # once at startup, which would race tailscaled at boot; the original IP
  # stays available in the `ip` label.
  smokepingHosts = {
    "192.168.1.1" = "router"; # local router (WiFi/LAN health, free)
    "192.168.100.1" = "dishy"; # the Starlink dish (free, doesn't touch the sky)
    "1.1.1.1" = "cloudflare"; # anycast reference 1 (general reachability)
    "8.8.8.8" = "google"; # anycast reference 2 (distinguishes provider blips)
    "100.83.4.27" = "droplet1"; # via tailnet
    "100.70.211.41" = "vault"; # via tailnet
  };
in
{
  # Exposes kernel/system metrics (CPU, memory, disk, network, temps)
  # on 127.0.0.1:9100.
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "127.0.0.1";
    enabledCollectors = [ "systemd" ]; # per-unit metrics: failed services etc.
  };

  # SMART health for the NVMe drive (temperature, wear, error counts) on
  # 127.0.0.1:9633. Autodiscovers disks; runs with just enough capabilities
  # to talk to the device.
  services.prometheus.exporters.smartctl = {
    enable = true;
    listenAddress = "127.0.0.1";
  };

  # Power metrics. Scaphandre (per-process watts) is marked broken in
  # nixpkgs (github.com/hubblo-org/scaphandre/issues/403); until that's
  # fixed, node_exporter's rapl collector gives whole-CPU watts and its
  # powersupplyclass collector gives real battery draw. Both are enabled
  # by default — they just need the RAPL driver loaded ("intel" in the
  # name is historical; the same driver serves AMD Zen)...
  boot.kernelModules = [ "intel_rapl_common" ];
  # ...and permission: the kernel makes /sys/class/powercap/*/energy_uj
  # root-only readable (CVE-2020-8694: energy readings can leak what other
  # processes do). Let node_exporter read them without running as root.
  systemd.services.prometheus-node-exporter.serviceConfig = {
    AmbientCapabilities = [ "CAP_DAC_READ_SEARCH" ];
    CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
  };

  # Per-process CPU/memory/IO grouped by command name on 127.0.0.1:9256 —
  # "how much RAM has the browser used this week". The catch-all pattern
  # groups every process by its comm name; add more specific entries first
  # if some deserve their own grouping.
  services.prometheus.exporters.process = {
    enable = true;
    listenAddress = "127.0.0.1";
    settings.process_names = [
      {
        name = "{{.Comm}}";
        cmdline = [ ".+" ];
      }
    ];
  };

  # Continuous ICMP latency probes on 127.0.0.1:9374 — the classic
  # smokeping latency/loss graphs. Targets (defined in smokepingHosts at
  # the top) are layered so problems can be localized: LAN hop -> dish ->
  # internet (two anycast references) -> tailnet machines. Data cost on
  # the metered Starlink link: four targets traverse it, ~4 MB/day total
  # at one ping each per 15s — negligible even in ocean mode. (The 1s
  # default would be ~15x that.)
  services.prometheus.exporters.smokeping = {
    enable = true;
    listenAddress = "127.0.0.1";
    pingInterval = "15s";
    hosts = lib.attrNames smokepingHosts;
  };

  # Backup metrics (snapshot count, age of newest snapshot, repo size) on
  # 127.0.0.1:9753 — good for alerting on "backups silently stopped".
  # Reuses the repo/credentials from backups.nix. Each refresh talks to B2
  # (API calls cost money above the free daily tier), hence the long
  # interval; scraping in between just serves the cached values.
  services.prometheus.exporters.restic = {
    enable = true;
    listenAddress = "127.0.0.1";
    inherit (config.services.restic.backups.home) repository passwordFile environmentFile;
    refreshInterval = 3600;
  };

  # Time-series database. Scrape targets go in prometheusConfig below —
  # when adding a new exporter, add a scrape_configs entry pointing at it.
  services.victoriametrics = {
    enable = true;
    listenAddress = "127.0.0.1:8428";
    retentionPeriod = "1y";
    prometheusConfig = {
      # 15s resolution instead of the 1m default — smoother graphs, and at
      # this series count still only ~1-2 GB for the full year.
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
          job_name = "smartctl";
          static_configs = [
            {
              targets = [
                "127.0.0.1:${toString config.services.prometheus.exporters.smartctl.port}"
              ];
            }
          ];
        }
        {
          job_name = "process";
          static_configs = [
            {
              targets = [
                "127.0.0.1:${toString config.services.prometheus.exporters.process.port}"
              ];
            }
          ];
        }
        {
          job_name = "smokeping";
          static_configs = [
            {
              targets = [
                "127.0.0.1:${toString config.services.prometheus.exporters.smokeping.port}"
              ];
            }
          ];
          # Rewrite the host label from the pinged IP to its display name.
          metric_relabel_configs = lib.mapAttrsToList (ip: name: {
            source_labels = [ "host" ];
            regex = lib.replaceStrings [ "." ] [ "\\." ] ip;
            target_label = "host";
            replacement = name;
          }) smokepingHosts;
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
          # VictoriaMetrics' own metrics: ingest rate, memory, disk usage.
          job_name = "victoriametrics";
          static_configs = [
            { targets = [ config.services.victoriametrics.listenAddress ]; }
          ];
        }
        {
          # Same for VictoriaLogs: log ingest rate, storage, query stats.
          job_name = "victorialogs";
          static_configs = [
            { targets = [ config.services.victorialogs.listenAddress ]; }
          ];
        }
      ];
    };
  };

  # Log database, same family as VictoriaMetrics. The journal is shipped
  # in via systemd-journal-upload below, so logs become searchable and
  # graphable in Grafana next to the metrics.
  services.victorialogs = {
    enable = true;
    listenAddress = "127.0.0.1:9428";
    # Default retention is only 7d; keep a year, matching the metrics.
    extraOptions = [ "-retentionPeriod=1y" ];
  };

  # Ship the journal into VictoriaLogs with systemd's own uploader — no
  # extra log-shipper daemon. journal-upload appends /upload to the URL,
  # landing on VictoriaLogs' /insert/journald/upload endpoint. It keeps a
  # cursor, so entries from before an upload outage are backfilled.
  services.journald.upload = {
    enable = true;
    settings.Upload.URL = "http://127.0.0.1:9428/insert/journald";
  };

  # With VictoriaLogs as the long-term store (and its ~10-20x better
  # compression), journald itself only needs to be a recent-history buffer
  # for `journalctl` use.
  services.journald.extraConfig = ''
    SystemMaxUse=500M
  '';

  # Dashboards. The VictoriaMetrics datasource is provisioned declaratively
  # (it's Prometheus-compatible, so the type is "prometheus") — nothing to
  # click through after a rebuild. VictoriaLogs needs its own datasource
  # plugin, which nixpkgs doesn't package; pin it from grafana.com.
  services.grafana = {
    enable = true;
    settings.server = {
      http_addr = "127.0.0.1";
      http_port = 3000;
    };
    # Key Grafana uses to encrypt secrets in its own database; NixOS 26.05
    # requires setting one explicitly. Like /etc/restic/password, it lives
    # outside the repo. Create it once before the first rebuild:
    #   sudo install -d -m 755 /etc/grafana
    #   openssl rand -base64 32 | sudo install -m 640 -o root -g grafana /dev/stdin /etc/grafana/secret_key
    # (If the grafana group doesn't exist yet, rebuild once, then re-run.)
    settings.security.secret_key = "$__file{/etc/grafana/secret_key}";
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
