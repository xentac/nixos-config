# Alerting for everything alba-nix monitors (docs/adr/0010):
#   vmalert (rules below, against VictoriaMetrics)
#     -> Alertmanager (routing, grouping, silences)
#       -> ntfy-alertmanager -> ntfy.sh topic on the phone
#       -> healthchecks.io, for the always-firing Watchdog (dead-man's switch)
#
# Two severities: `page` (loud, act within hours) and `warn` (silent,
# re-sent daily). Every rule has a runbook entry under "Alerts" in
# docs/alba-nix.md; a rule with nothing to write there doesn't belong
# here. Grafana does no alerting, it only shows these through its
# Alertmanager datasource.
#
# Everything binds localhost. Secrets (sops, alerting/*): the ntfy topic
# and the healthchecks ping URL.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  vm = "http://${config.services.victoriametrics.listenAddress}";
  alertmanagerPort = config.services.prometheus.alertmanager.port;
  bridgePort = 8111;
  grafanaUrl = "https://alba-grafana.stalk-darter.ts.net";
  runbook =
    name: "https://github.com/xentac/nixos-config/blob/main/docs/alba-nix.md#${lib.toLower name}";

  rule =
    {
      alert,
      expr,
      for ? "0s",
      severity,
      summary,
    }:
    {
      inherit alert expr for;
      labels = { inherit severity; };
      annotations = {
        inherit summary;
        runbook = runbook alert;
      };
    };

  # Seconds since the newest snapshot. The 14d window keeps donatello's
  # age growing while it is off and not pushing. Instances still named by
  # scrape address (127.0.0.1:9753) are pre-relabel leftovers that would
  # otherwise age into a false alert.
  backupAge =
    selector:
    ''time() - max by (instance) (last_over_time(restic_backup_timestamp{instance!~".*:[0-9]+",${selector}}[14d]))'';

  # One series per filesystem; alba-nix's btrfs subvolumes share a device.
  fsUsed = ''max by (instance, device) (100 * (1 - node_filesystem_avail_bytes{fstype=~"ext4|xfs|btrfs"} / node_filesystem_size_bytes))'';

  # Ping loss ratio per smokeping target over 10 min.
  smokepingLoss =
    selector:
    "(1 - sum by (host) (rate(smokeping_response_duration_seconds_count{${selector}}[10m])) / sum by (host) (rate(smokeping_requests_total{${selector}}[10m])))";

  rules.groups = [
    {
      name = "meta";
      rules = [
        {
          # Always fires; Alertmanager forwards it to healthchecks.io, which
          # alerts when the pings stop (boat, VM, pipeline or uplink down).
          alert = "Watchdog";
          expr = "vector(1)";
          labels.severity = "none";
          annotations.summary = "The alerting pipeline is alive.";
        }
      ];
    }
    {
      name = "hosts";
      rules = [
        (rule {
          alert = "TargetDown";
          expr = "up == 0";
          for = "15m";
          severity = "warn";
          summary = "{{ $labels.job }} on {{ $labels.instance }} has not been scraped for 15 minutes.";
        })
        (rule {
          alert = "SystemdUnitFailed";
          # Sticky for an hour: a deploy (or any restart) clears a failed
          # oneshot's state without fixing it, and its timer only fails it
          # again on the next run. Resolves after an hour without failure.
          expr = ''max_over_time(node_systemd_unit_state{state="failed"}[1h]) == 1'';
          for = "15m";
          severity = "warn";
          summary = "{{ $labels.name }} on {{ $labels.instance }} has failed in the last hour.";
        })
        (rule {
          alert = "FilesystemFull";
          expr = "${fsUsed} > 85";
          for = "30m";
          severity = "warn";
          summary = "{{ $labels.device }} on {{ $labels.instance }} is {{ $value | humanize }}% full.";
        })
        (rule {
          alert = "FilesystemFull";
          expr = "${fsUsed} > 95";
          for = "5m";
          severity = "page";
          summary = "{{ $labels.device }} on {{ $labels.instance }} is {{ $value | humanize }}% full.";
        })
        (rule {
          alert = "ClockNotSynced";
          expr = "node_timex_sync_status == 0";
          for = "30m";
          severity = "warn";
          summary = "The clock on {{ $labels.instance }} is not NTP-synchronised.";
        })
        (rule {
          # Both anycast references dark: the uplink, not one provider.
          # Only delivered once the uplink is back, so it reads as a record
          # of the outage; healthchecks.io reports it live.
          alert = "UplinkDown";
          expr = "min(${smokepingLoss ''host=~"cloudflare|google"''}) > 0.9";
          for = "5m";
          severity = "warn";
          summary = "The boat lost the internet: {{ $value | humanizePercentage }} ping loss to both cloudflare and google.";
        })
      ];
    }
    {
      name = "backups";
      interval = "15m";
      rules = [
        (rule {
          alert = "BackupStale";
          # Daily jobs on the always-on hosts; donatello is a laptop that
          # can sit closed for a weekend.
          expr = "(${backupAge ''instance!="donatello"''}) > 36 * 3600 or (${backupAge ''instance="donatello"''}) > 4 * 86400";
          for = "1h";
          severity = "warn";
          summary = "Newest restic snapshot of {{ $labels.instance }} is {{ $value | humanizeDuration }} old.";
        })
        (rule {
          alert = "BackupCheckFailed";
          expr = "last_over_time(restic_check_success[14d]) == 0";
          for = "1h";
          severity = "warn";
          summary = "restic check of {{ $labels.instance }}'s repository failed.";
        })
      ];
    }
    {
      # Signal K, i.e. the Victron GX. Temperatures arrive in kelvin.
      name = "boat";
      rules = [
        (rule {
          alert = "BatteryLow";
          expr = "signalk_electrical_batteries_0_capacity_stateOfCharge < 0.5";
          for = "15m";
          severity = "warn";
          summary = "House battery at {{ $value | humanizePercentage }}.";
        })
        (rule {
          alert = "BatteryLow";
          expr = "signalk_electrical_batteries_0_capacity_stateOfCharge < 0.3";
          for = "10m";
          severity = "page";
          summary = "House battery at {{ $value | humanizePercentage }}.";
        })
        (rule {
          # The lithium BMS is about to (or did) cut loads or charging.
          alert = "BatteryBmsBlocking";
          expr = ''{__name__=~"signalk_electrical_batteries_0_bms_allowTo(Charge|Discharge)"} == 0'';
          for = "1m";
          severity = "page";
          summary = "The battery BMS no longer allows {{ $labels.signalk_path }}.";
        })
        (rule {
          alert = "BatteryTemperature";
          expr = "signalk_electrical_batteries_0_temperature - 273.15 < 5 or signalk_electrical_batteries_0_temperature - 273.15 > 45";
          for = "10m";
          severity = "warn";
          summary = "House battery at {{ $value | humanize }} °C, outside 5-45 °C.";
        })
        (rule {
          # Forwards the GX's own alarms (overload, ripple, ...). The
          # starlinkOffshore plugin's notification is our metered input,
          # not an alarm.
          alert = "VictronAlarm";
          expr = ''{__name__=~"signalk_notifications_.+_state", __name__!~"signalk_notifications_starlinkOffshore_.+", value_str=~"alarm|emergency"}'';
          for = "1m";
          severity = "page";
          summary = "Victron alarm: {{ $labels.signalk_path }} is {{ $labels.value_str }}.";
        })
        (rule {
          alert = "VictronAlarm";
          expr = ''{__name__=~"signalk_notifications_.+_state", __name__!~"signalk_notifications_starlinkOffshore_.+", value_str=~"warn|alert"}'';
          for = "5m";
          severity = "warn";
          summary = "Victron warning: {{ $labels.signalk_path }} is {{ $labels.value_str }}.";
        })
      ];
    }
    {
      # Status codes are the Synology MIB's: 1 is normal everywhere.
      name = "hardware";
      rules = [
        (rule {
          alert = "VaultRaidDegraded";
          expr = ''raidStatus{job="snmp-vault"} == 11 or raidStatus{job="snmp-vault"} == 12'';
          severity = "page";
          summary = "vault {{ $labels.raidName }} is {{ if eq $value 11.0 }}degraded{{ else }}crashed{{ end }}.";
        })
        (rule {
          # diskStatus 4 = system partition failed, 5 = crashed;
          # diskHealthStatus 3 = critical, 4 = failing.
          alert = "VaultDiskUnhealthy";
          expr = ''label_copy({__name__=~"diskStatus|diskHealthStatus", job="snmp-vault"}, "__name__", "metric") >= 4 or label_copy(diskHealthStatus{job="snmp-vault"}, "__name__", "metric") == 3'';
          severity = "page";
          summary = "vault disk {{ $labels.diskID }} reports {{ $labels.metric }} {{ $value }}.";
        })
        (rule {
          alert = "VaultDiskUnhealthy";
          expr = ''diskHealthStatus{job="snmp-vault"} == 2'';
          severity = "warn";
          summary = "vault disk {{ $labels.diskID }} health is at warning.";
        })
        (rule {
          alert = "VaultHardwareFault";
          expr = ''label_copy({__name__=~"systemStatus|powerStatus", job="snmp-vault"}, "__name__", "metric") == 2'';
          severity = "page";
          summary = "vault reports {{ $labels.metric }} failed.";
        })
        (rule {
          alert = "VaultHardwareFault";
          expr = ''label_copy({__name__=~"systemFanStatus|cpuFanStatus", job="snmp-vault"}, "__name__", "metric") == 2'';
          severity = "warn";
          summary = "vault reports {{ $labels.metric }} failed.";
        })
        (rule {
          alert = "NvmeCriticalWarning";
          expr = "nvme_critical_warning > 0";
          severity = "page";
          summary = "{{ $labels.device }} on {{ $labels.instance }} raised NVMe critical warning {{ $value }}.";
        })
        (rule {
          alert = "SmartUnhealthy";
          expr = "smartmon_device_smart_healthy == 0";
          severity = "page";
          summary = "{{ $labels.disk }} on {{ $labels.instance }} fails its SMART health check.";
        })
        (rule {
          alert = "NvmeMediaErrors";
          expr = "increase(nvme_media_errors_total[1d]) > 0";
          severity = "warn";
          summary = "{{ $labels.device }} on {{ $labels.instance }} logged {{ $value }} media errors today.";
        })
        (rule {
          alert = "NvmeWearing";
          expr = "nvme_percentage_used_ratio > 0.8";
          severity = "warn";
          summary = "{{ $labels.device }} on {{ $labels.instance }} has used {{ $value | humanizePercentage }} of its rated endurance.";
        })
        (rule {
          alert = "PveGuestDown";
          expr = "(pve_onboot_status == 1 and on (id) pve_up == 0) * on (id) group_left (name) pve_guest_info";
          for = "15m";
          severity = "warn";
          summary = "proxmox guest {{ $labels.name }} ({{ $labels.id }}) starts on boot but is not running.";
        })
        (rule {
          # proxmox's SMART/NVMe/apt scripts refresh every ~15 min; its
          # restic.prom is daily and BackupStale already watches it.
          alert = "TextfileCollectorBroken";
          expr = ''time() - node_textfile_mtime_seconds{file!~".*/restic.prom"} > 3 * 3600'';
          severity = "warn";
          summary = "{{ $labels.file }} on {{ $labels.instance }} has not been rewritten for {{ $value | humanizeDuration }}.";
        })
        (rule {
          alert = "TextfileCollectorBroken";
          expr = "node_textfile_scrape_error == 1";
          for = "15m";
          severity = "warn";
          summary = "node_exporter on {{ $labels.instance }} cannot parse a textfile collector file.";
        })
      ];
    }
  ]
  ++ lib.optional config.services.paperless.enable {
    # Inputs pushed every 15 min by paperless-metrics (paperless.nix).
    name = "paperless";
    interval = "5m";
    rules = [
      (rule {
        alert = "PaperlessInboxStale";
        expr = "last_over_time(paperless_inbox_oldest_age_seconds[1h]) > 14 * 86400";
        severity = "warn";
        summary = "The oldest document in the paperless inbox is {{ $value | humanizeDuration }} old: time for a review.";
      })
      (rule {
        alert = "PaperlessDocumentExpiring";
        expr = "last_over_time(paperless_document_expires_timestamp_seconds[1h]) - time() < 30 * 86400";
        severity = "warn";
        summary = ''"{{ $labels.title }}" expires in {{ $value | humanizeDuration }}.'';
      })
      (rule {
        alert = "PaperlessMailFailing";
        # A dead login errors every 10-minute check: >12 in 6 h is two
        # hours of failure, not one GMX hiccup.
        expr = "last_over_time(paperless_mail_errors_6h[1h]) > 12";
        for = "30m";
        severity = "warn";
        summary = "Paperless logged {{ $value }} mail errors in 6 h: check the GMX account.";
      })
      (rule {
        # The inbox metric is pushed every run (0 when empty), so its
        # absence means the collector itself is broken.
        alert = "PaperlessMetricsMissing";
        expr = "absent_over_time(paperless_inbox_oldest_age_seconds[1h])";
        severity = "warn";
        summary = "paperless-metrics has not pushed for an hour.";
      })
    ];
  };

  # Same YAML the module writes to /etc, validated at build time.
  rulesFile = (pkgs.formats.yaml { }).generate "rules.yml" rules;
  checkedRules = pkgs.runCommand "vmalert-rules-checked" { } ''
    ${config.services.vmalert.package}/bin/vmalert -dryRun -rule=${rulesFile} > $out
  '';
in
{
  system.checks = [ checkedRules ];

  services.vmalert.instances."" = {
    enable = true;
    inherit rules;
    settings = {
      "httpListenAddr" = "127.0.0.1:8880";
      "datasource.url" = vm;
      "notifier.url" = [ "http://127.0.0.1:${toString alertmanagerPort}" ];
      # Alert state goes back into VictoriaMetrics (ALERTS series) and is
      # restored from it, so a restart doesn't reset every `for:` timer.
      "remoteWrite.url" = vm;
      "remoteRead.url" = vm;
      # Each alert's source link opens its query in Grafana's Explore.
      "external.url" = grafanaUrl;
      # The whole JSON pane is URL-encoded: ntfy-alertmanager turns this
      # link into an ntfy action button, and ntfy rejects raw commas and
      # quotes there (400 "actions invalid"). Go raw strings (backticks)
      # and `print`, because systemd's ExecStart parsing eats backslash
      # escapes and expands %-specifiers even inside quotes.
      "external.alert.source" =
        "explore?orgId=1&left={{ print `{\"datasource\":\"victoriametrics\",\"queries\":[{\"expr\":` (.Expr | jsonEscape) `,\"refId\":\"A\"}],\"range\":{\"from\":\"now-6h\",\"to\":\"now\"}}` | queryEscape }}";
    };
  };

  sops.secrets."alerting/healthchecks-url".restartUnits = [ "alertmanager.service" ];
  sops.secrets."alerting/ntfy-topic" = { };

  services.prometheus.alertmanager = {
    enable = true;
    listenAddress = "127.0.0.1";
    # Single instance: no HA gossip port.
    extraFlags = [ "--cluster.listen-address=" ];
    configuration = {
      route = {
        receiver = "ntfy";
        group_by = [
          "alertname"
          "instance"
        ];
        group_wait = "1m";
        group_interval = "10m";
        repeat_interval = "24h";
        routes = [
          {
            # healthchecks.io: period 5 min, grace 10 min.
            matchers = [ ''alertname="Watchdog"'' ];
            receiver = "healthchecks";
            group_wait = "0s";
            group_interval = "1m";
            repeat_interval = "5m";
          }
          {
            matchers = [ ''severity="page"'' ];
            receiver = "ntfy";
            repeat_interval = "4h";
          }
        ];
      };
      # A paging alert covers its own warning (FilesystemFull at 95% vs 85%).
      inhibit_rules = [
        {
          source_matchers = [ ''severity="page"'' ];
          target_matchers = [ ''severity="warn"'' ];
          equal = [
            "alertname"
            "instance"
            "device"
            "diskID"
          ];
        }
      ];
      receivers = [
        {
          name = "ntfy";
          webhook_configs = [
            {
              url = "http://127.0.0.1:${toString bridgePort}";
              send_resolved = true;
            }
          ];
        }
        {
          name = "healthchecks";
          webhook_configs = [
            {
              url_file = "/run/credentials/alertmanager.service/healthchecks-url";
              send_resolved = false;
            }
          ];
        }
      ];
    };
  };
  systemd.services.alertmanager.serviceConfig.LoadCredential = [
    "healthchecks-url:${config.sops.secrets."alerting/healthchecks-url".path}"
  ];

  # Alertmanager has no ntfy receiver; this bridge maps severity to ntfy
  # priority and edits the notification in place when an alert resolves.
  sops.templates."ntfy-alertmanager.scfg" = {
    restartUnits = [ "ntfy-alertmanager.service" ];
    content = ''
      http-address 127.0.0.1:${toString bridgePort}
      alert-mode single
      labels {
        order "severity"
        severity "page" {
          priority 5
          tags "rotating_light"
        }
        severity "warn" {
          priority 2
          tags "warning"
        }
      }
      resolved {
        update-notification true
        tags "white_check_mark"
        priority 1
      }
      ntfy {
        server https://ntfy.sh
        topic ${config.sops.placeholder."alerting/ntfy-topic"}
        generator-url-label Grafana
      }
      # Drops duplicate sends of a still-firing alert; shorter than the
      # 4 h page repeat so repeats get through.
      cache {
        type memory
        duration 3h
      }
    '';
  };
  systemd.services.ntfy-alertmanager = {
    description = "Alertmanager to ntfy bridge";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      DynamicUser = true;
      LoadCredential = "config:${config.sops.templates."ntfy-alertmanager.scfg".path}";
      ExecStart = "${pkgs.ntfy-alertmanager}/bin/ntfy-alertmanager --config %d/config";
      Restart = "on-failure";
    };
  };

  # Firing alerts and silences in Grafana (Alerting > Alertmanager).
  services.grafana.provision.datasources.settings.datasources = [
    {
      name = "Alertmanager";
      uid = "alertmanager";
      type = "alertmanager";
      url = "http://127.0.0.1:${toString alertmanagerPort}";
      jsonData.implementation = "prometheus";
    }
  ];
}
