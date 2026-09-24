# Grafana dashboards: editing and recording changes

How dashboards are managed on both Grafana hosts — alba-nix
(`modules/server/monitoring.nix`) and donatello
(`modules/desktop/monitoring.nix`) — and the round-trip for editing
them without losing the changes to Grafana's database.

## How provisioning works

All dashboards are provisioned read-only out of the Nix store. Each
monitoring module builds a `dashboardsDir` link farm and points a
single dashboard provider at it with
`foldersFromFilesStructure = true`, so an entry named
`"Boat/boat-internals.json"` lands in the "Boat" folder in Grafana.
Nothing about dashboards lives in Grafana's own database; the store
path is the source of truth and every deploy converges Grafana to it.

There are two kinds of entries in `dashboardsDir`:

- **Pinned upstream dashboards** — fetched from grafana.com by
  `(id, rev, hash)` via the `grafanaDashboard` helper (or from an
  exporter's repo via `patchDashboard`). These are *not* forked into
  the repo.
- **Hand-written dashboards** — plain JSON checked in next to the
  module, in `modules/server/grafana-dashboards/` and
  `modules/desktop/grafana-dashboards/`.

## Editing a hand-written dashboard

Because the dashboard is provisioned, Grafana lets you edit it live in
the browser but refuses to persist a Save — and the refusal dialog is
exactly the export mechanism:

1. Edit panels/variables in the Grafana UI as normal. Changes apply to
   your browser session immediately, so you can iterate against real
   data.
2. Hit **Save**. Grafana pops a "cannot save provisioned dashboard"
   dialog showing the full updated JSON with a copy button — copy it.
   (Alternatively: Dashboard settings → **JSON Model**, any time.)
3. Paste it over the repo file and strip the volatile fields Grafana
   adds. The checked-in files carry no `id`/`version` keys and a
   stable hand-picked `uid`:

   ```sh
   jq 'del(.id, .version)' pasted.json \
     > modules/server/grafana-dashboards/boat-internals.json
   ```

   Keep the `uid` as-is — it's what makes the provisioner update the
   existing dashboard in place instead of creating a duplicate.
4. Rebuild and deploy the host; the provisioner picks up the new file
   on activation. Diff the JSON before committing — it's readable
   enough to sanity-check that only the intended panels changed.

Do **not** set `options.allowUiUpdates = true` on the provider to make
Save work. Edits would land in Grafana's database and silently drift
from the repo, defeating the declarative setup.

## Editing a pinned upstream dashboard

Don't fork upstream dashboards into local JSON. Instead:

- To pick up upstream changes, bump `rev` and `hash` in the
  `grafanaDashboard { ... }` entry.
- To fix author mistakes or adapt to our environment, add `replace`
  string substitutions — literal from→to swaps applied inside every
  string value of the JSON. See the smokeping entry (hardcoded target
  → template variables) and the synology entry (`$NASDevices` constant
  → `1`) in `modules/server/monitoring.nix` for examples.
- Datasource wiring is automatic: `patchDashboard` resolves `__inputs`
  placeholders (prometheus-type inputs → the `victoriametrics`
  datasource uid, constants → their declared defaults).

If a pinned dashboard needs changes beyond what `replace` can express,
that's the point to fork it: export the JSON Model, check it in, and
move the entry to a local `path`, noting where it came from.

## Adding a new custom dashboard

1. Build it in the Grafana UI (it lives in Grafana's database while
   you iterate).
2. Export the JSON Model, `jq 'del(.id, .version)'`, set a stable
   kebab-case `uid`, and drop the file in the host's
   `grafana-dashboards/` directory.
3. Add a `dashboardsDir` entry named `"<Folder>/<name>.json"` with
   `path = ./grafana-dashboards/<name>.json`, plus a comment saying
   why it's hand-written (convention: the existing entries all explain
   themselves).
4. Deploy, confirm the provisioned copy renders, then delete the
   database copy you built in step 1 so there aren't two.
