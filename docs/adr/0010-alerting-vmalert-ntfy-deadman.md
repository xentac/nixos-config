# 0010 — alerts come from vmalert on alba-nix, delivered by ntfy, watched by a dead-man's switch

Date: 2026-10-19. Status: accepted.

## Context

alba-nix already collects everything worth alerting on: its own and
proxmox's node metrics, vault over SNMP, signalk, restic for all three
backed-up machines (donatello pushes its own), and paperless health.
Until now nothing watched those numbers; problems were found by
looking at a dashboard.

Grafana can evaluate alert rules itself, and provisioned Grafana rules
were briefly drafted for paperless. Grafana's provisioning format,
though, is verbose JSON (a query, an expression, and a threshold for
every rule). It can't be checked at build time, and a rule edited in
the UI drifts from the repo. The alternative is vmalert, the
VictoriaMetrics evaluator. It reads plain Prometheus rule YAML, runs
against the same VictoriaMetrics, and pairs with Alertmanager for
routing, grouping, silences and inhibition.

Delivery must be free, must reach a phone, and must not get lost the
way email does. The monitor sits on the boat with the things it
watches, so the failures that matter most (power, the VM, the uplink)
also silence the alerter.

## Decision

- **vmalert evaluates every alert rule**, written in Nix in
  `modules/server/alerting.nix` and checked with `vmalert -dryRun` at
  build time. Grafana does no alerting: neither alba-grafana nor
  donatello's. Grafana gets an Alertmanager datasource, so firing
  alerts and silences are visible there.
- **Alertmanager routes.** There are two severities, and every alert
  carries one:
  - `page`: needs action within hours. Sent at ntfy priority 5,
    re-sent every 4 h while firing.
  - `warn`: fix it when convenient. Sent at ntfy priority 2 (no sound,
    sits in the notification shade), re-sent every 24 h.
- **ntfy.sh carries notifications**, through ntfy-alertmanager, a small
  bridge running on alba-nix. Alertmanager has no native ntfy
  receiver. The public ntfy.sh server is used under a long random
  topic name, kept in sops. A self-hosted ntfy on alba-nix would die
  with the thing it reports on.
- **A dead-man's switch on healthchecks.io** (free tier). A `Watchdog`
  alert always fires, and Alertmanager forwards it to a healthchecks
  ping URL every 5 minutes. If the pings stop, healthchecks.io notifies
  from outside the boat. That covers the boat losing power, alba-nix
  being down, vmalert or Alertmanager being dead, or the uplink being
  down.
- **Every rule has a runbook entry** under "Alerts" in
  `docs/alba-nix.md`. A rule that has nothing to write there, or that
  gets ignored twice, is deleted or retuned.

## Consequences

- One alerting point for the whole fleet. Alerts about donatello come
  from alba-nix, using what donatello pushes, so donatello stays an
  island and doesn't duplicate rules.
- Rules are ordinary PromQL/MetricsQL. Rules from the community and
  from exporters' docs paste in directly.
- Notification text goes through ntfy.sh, a third party. It must never
  contain secrets, and anyone who learns the topic name can read it and
  post to it.
- Watchdog pings use a few hundred bytes every 5 minutes, which is
  negligible even while **metered**. Alerts are rarer still.
- While the uplink is down, alerts queue in Alertmanager and are retried.
  healthchecks.io then reports the outage on its own.
- Three more services on alba-nix (vmalert, alertmanager,
  ntfy-alertmanager). All three are small and bound to localhost.
- Free-tier dependencies: ntfy.sh and healthchecks.io. Both are
  replaceable: ntfy with a Telegram receiver, and healthchecks with any
  push-based dead-man service.
