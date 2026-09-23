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
  # Smokeping targets, IP -> display name; same layering idea as the
  # laptop's list (modules/desktop/monitoring.nix): LAN hop -> NAS ->
  # dish -> internet -> tailnet, so a problem can be localized. Raw IPs
  # because the prober resolves names only once at startup, which would
  # race tailscaled at boot; the original IP stays in the `ip` label.
  smokepingHosts = {
    "192.168.1.1" = "router"; # boat router (LAN health, free)
    "192.168.1.223" = "vault"; # the NAS the SMB mounts depend on (free)
    "192.168.100.1" = "dishy"; # the Starlink dish (free, doesn't touch the sky)
    "1.1.1.1" = "cloudflare"; # anycast reference 1 (general reachability)
    "8.8.8.8" = "google"; # anycast reference 2 (distinguishes provider blips)
    "100.83.4.27" = "droplet1"; # tailnet path over the uplink
  };

  # SNMP modules polled from vault, all straight out of snmp_exporter's
  # shipped snmp.yml (docs/vault-monitoring.md): `synology` covers the
  # SYNOLOGY-* MIBs including the per-drive SMART table; the rest are the
  # generic host/interface modules dashboard 14284 graphs. One scrape
  # walks them all (repeated ?module= params, supported since 0.23).
  snmpModules = [
    "synology" # disks, SMART, RAID, services, fans/PSU, DSM upgrade flag
    "if_mib" # network interfaces
    "hrStorage" # volume + memory usage
    "hrSystem" # process count
    "system" # sysUpTime
    "ucd_la_table" # load average
    "ucd_memory" # memory detail
    "ucd_system_stats" # CPU
  ];

  # The exporter's shipped config filtered down to snmpModules, plus a v3
  # auth block for vault's SNMP user. Credentials are $VAR placeholders
  # expanded at service start from the sops env file (the exporter only
  # env-expands auth fields, so module bodies can't be mangled; a missing
  # variable is a hard startup error, not an empty credential).
  snmpConfigFile =
    pkgs.runCommand "snmp-vault.yml"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        yq '{
          "auths": {
            "vault": {
              "version": 3,
              "security_level": "authNoPriv",
              "auth_protocol": "SHA",
              "username": "$SNMP_USER",
              "password": "$SNMP_AUTH_PASSWORD"
            }
          },
          "modules": .modules | pick(${builtins.toJSON snmpModules})
        }' ${pkgs.prometheus-snmp-exporter.src}/snmp.yml > $out
      '';

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

  # Dashboards pinned by hash — the declarative replacement for importing
  # by hand. grafanaDashboard fetches from grafana.com by (id, revision);
  # patchDashboard is the shared jq pass for dashboards that come from
  # elsewhere (e.g. an exporter's own repo). Most dashboards pick their
  # datasource via a template variable (defaulting to the default
  # datasource); the jq pass hard-wires the ones that instead declare a
  # `__inputs` placeholder: prometheus-type inputs point at our
  # VictoriaMetrics datasource uid, and constant inputs get their
  # declared default (normally filled in by the manual import wizard,
  # which provisioning bypasses). `replace` is for patching author
  # mistakes: literal string substitutions applied inside every string
  # value of the dashboard JSON.
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
    {
      name = "System/node-exporter-full.json";
      path = grafanaDashboard {
        id = 1860;
        rev = 45;
        hash = "sha256-GExrdAnzBtp1Ul13cvcZRbEM6iOtFrXXjEaY6g6lGYY=";
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
    # Hand-written (grafana.com has no journald explorer — the official
    # VictoriaLogs Explorer, id 22759, is Kubernetes-shaped). Filters by
    # host/unit/level plus a free-form LogsQL box; journald's PRIORITY is
    # auto-converted to the `level` field on ingestion.
    {
      name = "System/journald-explorer.json";
      path = ./grafana-dashboards/journald-explorer.json;
    }
    # Richest of the smokeping_prober dashboards on grafana.com: status
    # history, loss, jitter, TTL, response-time heatmap, per (hostname,
    # ip) target pair. Its two jitter queries hardcode the author's own
    # target instead of the dashboard's template variables (upstream bug,
    # panels "Today's Jittering" and "Avg. Response Time"); rewrite them
    # to the same templated selector every other panel uses.
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
    # grafana.com has no dashboard for msroest/sabnzbd_exporter; upstream
    # ships one in its repo. Pinned to the same tag nixpkgs builds the
    # exporter from (a package bump surfaces here as a hash mismatch).
    # It hardcodes the author's prometheus datasource uid in every panel;
    # rewrite it to ours.
    {
      name = "Media/sabnzbd.json";
      path = patchDashboard "sabnzbd-exporter-dashboard.json" {
        src = pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/msroest/sabnzbd_exporter/${pkgs.prometheus-sabnzbd-exporter.version}/examples/dashboard.json";
          hash = "sha256-y4TLaS0JhczQuRg0Fnz0IsybwSwJVDenHs8X9bqy0bY=";
        };
        replace."000000001" = "victoriametrics";
      };
    }
    # Built against snmp_exporter's default synology config — exactly what
    # the snmp-vault job scrapes. Its "Synology's Down" stat compares
    # count(systemStatus) against the author's constant NASDevices=4
    # (normally edited during the import wizard); rewrite its two
    # expressions to expect our single NAS.
    {
      name = "NAS/synology.json";
      path = grafanaDashboard {
        id = 14284;
        rev = 10;
        hash = "sha256-6yeoeOYM0QgFp4yhZLKqubUhi80ZPJSeyKoq3FkpIGE=";
        replace = {
          "$NASDevices-count(systemStatus)" = "1-count(systemStatus)";
          "count(systemStatus)-$NASDevices" = "count(systemStatus)-1";
        };
      };
    }
    # Hand-written port of the old InfluxDB-backed "Boat internals"
    # dashboard, rebuilt against the signalk scrape job below (battery/
    # solar/tank/Starlink metrics). Per-charger panels join each metric
    # with its electrical.solar.<id>.name companion (the human-readable
    # name rides in the value_str label), so new chargers appear without
    # editing the dashboard. String states (charging mode, Starlink
    # status/software) can't cross Prometheus as strings: charging mode
    # uses chargingModeNumber (the Victron VE.Bus /State enum) with value
    # mappings; the Starlink panels draw one timeline row per value_str.
    {
      name = "Boat/boat-internals.json";
      path = ./grafana-dashboards/boat-internals.json;
    }
    # Pinned to rev 2, not the latest rev 3: rev 3 graphs metrics that only
    # exist in restic-exporter >= 2.0 (restic_size_total, compression ratio,
    # files new/changed, ...) while nixpkgs still packages 1.7.0, leaving
    # half the dashboard permanently "No data". Rev 2 uses exactly the 1.7.0
    # metric set. Bump back to rev 3 when the nixpkgs exporter reaches 2.x.
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
  # Kernel/system metrics on 127.0.0.1:9100.
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "127.0.0.1";
    enabledCollectors = [ "systemd" ]; # per-unit metrics: failed services etc.
  };

  # Continuous ICMP latency probes on 127.0.0.1:9374 — the classic
  # smokeping latency/loss graphs. Targets are defined in smokepingHosts
  # at the top. Data cost on the metered Starlink link: three targets
  # traverse it, ~3 MB/day total at one ping each per 15s — negligible
  # even in ocean mode.
  services.prometheus.exporters.smokeping = {
    enable = true;
    listenAddress = "127.0.0.1";
    pingInterval = "15s";
    hosts = lib.attrNames smokepingHosts;
  };

  # A pinger whose FIRST send fails exits permanently while the exporter
  # process stays alive, so a boot-time race against the network silently
  # kills probing of most targets until the next restart. Hold the unit
  # until the network is actually up.
  systemd.services.prometheus-smokeping-exporter = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
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

  # Queue/throughput metrics from sabnzbd (media.nix): queue size and
  # remaining bytes, download rate, paused state, per-server totals.
  services.prometheus.exporters.sabnzbd = {
    enable = true;
    listenAddress = "127.0.0.1";
    servers = [
      {
        baseUrl = "http://127.0.0.1:${toString config.services.sabnzbd.settings.misc.port}${config.services.sabnzbd.settings.misc.url_base}";
        apiKeyFile = config.sops.secrets."sabnzbd/api_key".path;
      }
    ];
  };

  # SNMP proxy-exporter on 127.0.0.1:9116 — polls vault (the Synology NAS)
  # over SNMPv3 on demand, per docs/vault-monitoring.md. Nothing installed
  # on the NAS beyond enabling its SNMP service.
  services.prometheus.exporters.snmp = {
    enable = true;
    listenAddress = "127.0.0.1";
    configurationPath = snmpConfigFile;
    environmentFile = config.sops.secrets."snmp/environment".path;
  };

  # Env file consumed by snmpConfigFile's placeholders, two lines:
  #   SNMP_USER=<DSM SNMPv3 username>
  #   SNMP_AUTH_PASSWORD=<DSM SNMPv3 auth password (SHA, no privacy)>
  # Read by systemd as root when spawning the service, so default root
  # ownership is fine. restartUnits because nothing else ties the secret's
  # content to the unit: without it a credential change deploys but the
  # exporter keeps running with the old env until something else restarts
  # it.
  sops.secrets."snmp/environment".restartUnits = [ "prometheus-snmp-exporter.service" ];

  # The same api_key that lives inside sabnzbd/secrets_ini (media.nix),
  # duplicated as a bare value because the exporter wants a file holding
  # only the key — rotate both together. Read by systemd (LoadCredential)
  # as root, so default root ownership is fine.
  sops.secrets."sabnzbd/api_key" = { };

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
          job_name = "sabnzbd";
          static_configs = [
            {
              targets = [
                "127.0.0.1:${toString config.services.prometheus.exporters.sabnzbd.port}"
              ];
            }
          ];
        }
        {
          # SNMP scrapes are proxied: the target is a URL param and the
          # actual connection goes to the local exporter, which walks vault
          # live on every scrape. The full walk (SMART table included) takes
          # seconds on a NAS, so poll gently and allow it to run long.
          job_name = "snmp-vault";
          metrics_path = "/snmp";
          scrape_interval = "1m";
          scrape_timeout = "50s";
          params = {
            auth = [ "vault" ];
            module = snmpModules;
          };
          static_configs = [
            { targets = [ "192.168.1.223" ]; }
          ];
          relabel_configs = [
            {
              source_labels = [ "__address__" ];
              target_label = "__param_target";
            }
            {
              target_label = "instance";
              replacement = "vault";
            }
            {
              target_label = "__address__";
              replacement = "127.0.0.1:${toString config.services.prometheus.exporters.snmp.port}";
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
        {
          job_name = "signalk";
          metrics_path = "/signalk/v1/api/prometheus";
          scheme = "https";
          # The exporter emits mostly bare metric names (navigation_*,
          # sensors_*, environment_*); prefix them at scrape time so the
          # shared namespace stays legible. Its own signalk_prometheus_
          # exporter_* meta-metric comes out double-prefixed — harmless.
          metric_relabel_configs = [
            {
              source_labels = [ "__name__" ];
              regex = "(.*)";
              target_label = "__name__";
              replacement = "signalk_$1";
            }
          ];
          static_configs = [
            {
              targets = [
                "signalk2.stalk-darter.ts.net"
              ];
            }
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
        # Entries in dashboardsDir are named "<Folder>/<file>.json"; the
        # first-level directory becomes the dashboard's Grafana folder.
        options.foldersFromFilesStructure = true;
      }
    ];
  };
}
