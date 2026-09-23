# Local monitoring stack: exporters -> VictoriaMetrics -> Grafana, plus
# journald -> VictoriaLogs -> Grafana for logs. VictoriaMetrics speaks the
# Prometheus protocol and scrapes exporters itself, so there's no separate
# Prometheus process. Everything binds to localhost only.
#
# Grafana lives at http://localhost:3000 (first login admin/admin, it
# prompts for a new password). Import dashboard ID 1860 ("Node Exporter
# Full") for a complete system overview; battery/power and restic
# dashboards are provisioned declaratively (dashboardsDir below).
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

  # nixpkgs stamps buildinfo.Version with the bare version ("1.126.0"),
  # but upstream release builds use "victoria-metrics-…-tags-v1.126.0".
  # The stock dashboards' job/version template variables filter on that
  # prefix (version=~"victoria-metrics-.*"), so with a nixpkgs build
  # every panel shows No Data. Restamp the upstream format. Tests are
  # skipped: one asserts buildinfo.Version is unset, and the package's
  # preCheck workaround only knows the bare-version form. (Same fix as
  # modules/server/monitoring.nix.)
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

  # Dashboards pinned by hash — the declarative replacement for importing
  # by hand. Same helpers as modules/server/monitoring.nix (donatello is
  # deliberately self-contained, so the code is duplicated rather than
  # shared). patchDashboard resolves a downloaded dashboard's `__inputs`
  # placeholders: prometheus-type inputs point at our VictoriaMetrics
  # datasource uid, constant inputs get their declared default. `replace`
  # is for patching author mistakes: literal string substitutions applied
  # inside every string value of the dashboard JSON.
  patchDashboard =
    name:
    {
      src,
      replace ? { },
    }:
    pkgs.runCommand name
      {
        inherit src;
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        jq 'reduce (.__inputs // [])[] as $i (.;
              if $i.pluginId == "prometheus"
              then walk(if . == ("''${" + $i.name + "}") then "victoriametrics" else . end)
              elif $i.type == "constant"
              then walk(if . == ("''${" + $i.name + "}") then $i.value else . end)
              else . end)
            | del(.__inputs)
            ${
              lib.concatStrings (
                lib.mapAttrsToList (
                  from: to:
                  "| walk(if type == \"string\" then (split(${builtins.toJSON from}) | join(${builtins.toJSON to})) else . end)"
                ) replace
              )
            }' "$src" > "$out"
      '';

  grafanaDashboard =
    {
      id,
      rev,
      hash,
      replace ? { },
    }:
    patchDashboard "grafana-dashboard-${toString id}-rev${toString rev}.json" {
      src = pkgs.fetchurl {
        url = "https://grafana.com/api/dashboards/${toString id}/revisions/${toString rev}/download";
        inherit hash;
      };
      inherit replace;
    };

  dashboardsDir = pkgs.linkFarm "grafana-dashboards" [
    # The same dashboard set as modules/server/monitoring.nix minus the
    # server-only sabnzbd one — donatello runs the same stack (node
    # exporter, smokeping, VictoriaMetrics/Logs, restic), and these were
    # previously imported by hand. Provisioning a dashboard with the same
    # dashboard uid replaces the hand-imported DB copy, which is also what
    # repairs their baked-in references to the pre-migration datasource
    # uids.
    {
      name = "System/node-exporter-full.json";
      path = grafanaDashboard {
        id = 1860;
        rev = 45;
        hash = "sha256-GExrdAnzBtp1Ul13cvcZRbEM6iOtFrXXjEaY6g6lGYY=";
      };
    }
    # SMART health for the NVMe drive (smartctl exporter below; desktop-
    # only, the server has no smartctl exporter). Two panels pair a
    # SATA-attribute query with an NVMe query; only the NVMe half returns
    # data here, which is expected.
    {
      name = "System/smartctl.json";
      path = grafanaDashboard {
        id = 22604;
        rev = 3;
        hash = "sha256-gpm/4rzcNv6br8L8cs9O6iWEScojfImWUi1uRXW8UpM=";
      };
    }
    {
      name = "Monitoring/victoriametrics-single-node.json";
      path = grafanaDashboard {
        id = 10229;
        rev = 58;
        hash = "sha256-ohLgCHAdCSV9b3YkRAPPqCGOZaMKg1VzQK9dHlm9HAM=";
      };
    }
    {
      name = "Monitoring/victorialogs-single-node.json";
      path = grafanaDashboard {
        id = 22084;
        rev = 11;
        hash = "sha256-XCS5f54tPxc8t9ppEX0ahzw8ufex6K3MIBbDL6tMoIY=";
      };
    }
    # Hand-written journald explorer, shared with the server (it's the
    # same VictoriaLogs setup on both).
    {
      name = "System/journald-explorer.json";
      path = ../server/grafana-dashboards/journald-explorer.json;
    }
    # Same upstream-bug patch as the server: the two jitter queries
    # hardcode the author's own target instead of the dashboard's
    # template variables; rewrite them to the templated selector every
    # other panel uses.
    {
      name = "System/smokeping.json";
      path = grafanaDashboard {
        id = 22471;
        rev = 1;
        hash = "sha256-LeUnVjQpFO8uEttnPpZSazhJtJRXsrHG/1pPKKib48I=";
        replace = {
          "host=\"home.havlas.me\",ip=\"2a0c:c500:a828::3c\",job=\"smokeping\"" =
            "host=\"\${hostname:raw}\",ip=\"\${host:raw}\",job=\"$job\"";
        };
      };
    }
    # Hand-written battery/power dashboard: charge, watts in/out vs CPU
    # package power (RAPL), AC state, long-term battery health. Built on
    # node_exporter's powersupplyclass + rapl collectors (see the power
    # metrics section below).
    {
      name = "System/battery.json";
      path = ./grafana-dashboards/battery.json;
    }
    # Companion dashboard to the restic exporter. Pinned to rev 2, not the
    # latest rev 3: rev 3 graphs metrics that only exist in restic-exporter
    # >= 2.0 (restic_size_total, compression ratio, files new/changed, ...)
    # while nixpkgs still packages 1.7.0, leaving half the dashboard
    # permanently "No data". Rev 2 uses exactly the 1.7.0 metric set. Bump
    # back to rev 3 when the nixpkgs exporter reaches 2.x.
    {
      name = "System/restic-exporter.json";
      path = grafanaDashboard {
        id = 17554;
        rev = 2;
        hash = "sha256-5JwafWrhvfy73p6be2pWpvunMsMIDcFDjhDPlrlmsPw=";
      };
    }
  ];
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
  # 127.0.0.1:9633. Pinned to the internal drive: autodiscovery also finds
  # the Framework 1TB Expansion Card, whose ASMedia USB bridge chokes on
  # the SMART passthrough command — every 60s poll triggered a UAS reset
  # until the card wedged and fell off the bus.
  services.prometheus.exporters.smartctl = {
    enable = true;
    listenAddress = "127.0.0.1";
    devices = [ "/dev/nvme0" ];
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

  # A pinger whose FIRST send fails exits permanently while the exporter
  # process stays alive, so a boot-time race against WiFi silently kills
  # probing of most targets until the next restart. Hold the unit until
  # the network is actually up.
  systemd.services.prometheus-smokeping-exporter = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
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
    package = restampVersion pkgs.victoriametrics "victoria-metrics";
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
    package = restampVersion pkgs.victorialogs "victoria-logs";
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
  sops.secrets."grafana/secret_key".owner = "grafana";

  services.grafana = {
    enable = true;
    settings.server = {
      http_addr = "127.0.0.1";
      http_port = 3000;
    };
    # Key Grafana uses to encrypt secrets in its own database; NixOS 26.05
    # requires setting one explicitly. Comes from sops (secrets/donatello.yaml),
    # decrypted to a grafana-owned file at activation.
    settings.security.secret_key = "$__file{${config.sops.secrets."grafana/secret_key".path}}";
    declarativePlugins = [
      (pkgs.grafanaPlugins.grafanaPlugin {
        pname = "victoriametrics-logs-datasource";
        version = "0.32.0";
        zipHash = "sha256-ggTQl7F/U7HDpxdhBHc0t5gL2YNxDGz8742Tir5e7vA=";
      })
    ];
    # Migration shim: these datasources were first provisioned without
    # explicit uids, so they sit in grafana.db under auto-generated ones.
    # Grafana's provisioner can't change a datasource's uid — it updates
    # by the NEW uid, finds nothing, and aborts startup with "data source
    # not found". Deleting by name first (a no-op once migrated) lets them
    # be recreated with the fixed uids below.
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
        # Entries in dashboardsDir are named "<Folder>/<file>.json"; the
        # first-level directory becomes the dashboard's Grafana folder.
        options.foldersFromFilesStructure = true;
      }
    ];
  };
}
