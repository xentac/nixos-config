# paperless-ngx: the household's scanned and emailed documents, OCR'd and
# searchable. Native nixpkgs module, per docs/adr/0001; the workflow it
# serves (inbox review, document types, `expires`) is docs/paperless.md.
#
# Everything paperless owns — SQLite DB, search index, classifier, the
# originals and OCR'd archive PDFs — stays under /var/lib/paperless, so
# backups.nix's snapshot→restic→B2 job covers it consistently. vault only
# gets a nightly human-readable export as a second copy (docs/adr/0009).
#
# Documents arrive by phone app, web upload and an IMAP mailbox (a
# dedicated Gmail account). Mail accounts, rules, users, tags and custom
# fields all live in paperless's DB and are set up in its UI, not here —
# so the Gmail app password is in the DB (and the restic backup), not in
# sops. No consume folder until there's a scanner aboard.
#
# Binds localhost; caddy.nix publishes it as the tailnet name "paperless".
# Restrict that node in the tailnet ACL to Jason's and his wife's devices,
# like fava. Paperless's own login is the second layer.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.paperless;
  exportDir = "/srv/paperless-export"; # the vault mount, mounts.nix

  # The units the stock exporter stops for a consistent export.
  paperlessUnits = [
    "paperless-consumer.service"
    "paperless-scheduler.service"
    "paperless-task-queue.service"
    "paperless-web.service"
  ];
in
{
  sops.secrets."paperless/admin-password" = {
    owner = cfg.user;
  };
  # API token of the view-only `metrics` user, created in the UI after the
  # first deploy (docs/alba-nix.md). Holds the placeholder `unset` until then.
  sops.secrets."paperless/metrics-token" = { };
  services.paperless = {
    enable = true;
    # Superuser created on first start; the household accounts are made in
    # the UI.
    passwordFile = config.sops.secrets."paperless/admin-password".path;
    settings = {
      PAPERLESS_ADMIN_USER = "xentac";
      PAPERLESS_URL = "https://paperless.stalk-darter.ts.net";
      PAPERLESS_OCR_LANGUAGE = "eng";
      # One OCR job at a time, single-threaded: a batch of scans must not
      # saturate the hot shared NVMe or crowd the media stack.
      PAPERLESS_TASK_WORKERS = 1;
      PAPERLESS_THREADS_PER_WORKER = 1;
      # Media and export file names: 2026/Insurer/Policy renewal.pdf.
      PAPERLESS_FILENAME_FORMAT = "{{ created_year }}/{{ correspondent }}/{{ title }}";
    };
    # The stock exporter would create its directory with tmpfiles, which
    # stats the vault automount at boot (boat rule: boot never waits on the
    # NAS). The equivalent unit is below instead.
    exporter.enable = false;
  };

  # Nightly mirror of every document (plus manifest.json) onto vault,
  # named by PAPERLESS_FILENAME_FORMAT. Same shape as the stock exporter:
  # paperless is stopped for the run and brought back pass or fail. If
  # vault is down the soft mount errors out, the run fails, paperless
  # comes back, and the next night tries again. Thumbnails are skipped
  # (regenerated on import); --delete mirrors deletions, with vault's
  # snapshots of the share as the undo.
  systemd.services.paperless-export = {
    description = "Export paperless documents to vault";
    startAt = "03:30";
    serviceConfig = {
      Type = "oneshot";
      User = cfg.user;
      WorkingDirectory = cfg.dataDir;
    };
    unitConfig = {
      Conflicts = paperlessUnits;
      After = paperlessUnits;
      OnFailure = paperlessUnits;
      OnSuccess = paperlessUnits;
    };
    path = [ cfg.manage ];
    script = ''
      paperless-manage document_exporter ${exportDir} \
        --delete --use-filename-format --no-thumbnail \
        --no-progress-bar --no-color
    '';
  };

  # Alerting inputs (paperless-metrics.sh): every 15 min, pushed into
  # VictoriaMetrics for the paperless rules in alerting.nix. Runs on the
  # same host, with paperless's own token, so no foreign credentials are
  # involved.
  systemd.services.paperless-metrics = {
    description = "Push paperless inbox/expiry/mail health to VictoriaMetrics";
    startAt = "*:0/15";
    after = [ "paperless-web.service" ];
    environment = {
      PAPERLESS = "http://${cfg.address}:${toString cfg.port}";
      VM = "http://${config.services.victoriametrics.listenAddress}";
      VL = "http://${config.services.victorialogs.listenAddress}";
    };
    serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;
      LoadCredential = "token:${config.sops.secrets."paperless/metrics-token".path}";
      ExecStart = lib.getExe (
        pkgs.writeShellApplication {
          name = "paperless-metrics";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.curl
            pkgs.jq
          ];
          text = builtins.readFile ./paperless-metrics.sh;
        }
      );
    };
  };
}
