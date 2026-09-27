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

   Grafana 13 only emits the **v2 schema** (Kubernetes-style:
   `apiVersion: dashboard.grafana.app/v2`, panels under
   `spec.elements`/`layout`) — the "Classic" export option is broken
   and emits v2 anyway (grafana/grafana#126641, #123607). So
   hand-written dashboards migrate from the classic model to v2 as
   they get edited; file provisioning accepts both formats
   side by side, v2 as the full resource with that `apiVersion`.
3. Paste it over the repo file, then normalize it in place:

   ```sh
   just dashboard modules/server/grafana-dashboards/boat-internals.json
   ```

   The recipe handles either format and rewrites the file in jq's
   stable formatting so diffs stay clean:

   - **classic model** (has `.panels`): strips the volatile
     `id`/`version` keys.
   - **v2 export** (full resource, or just the bare `spec` — the
     broken "Classic" option produces that): rebuilds a minimal
     wrapper of `apiVersion`/`kind`/`metadata.name`/`spec`, dropping
     the server-side `metadata` (`resourceVersion`, timestamps, the
     provisioning store path) that would churn on every deploy.

   The dashboard uid — `.uid` in classic, `.metadata.name` in v2 —
   must match the previous revision in git, and the recipe refuses if
   it doesn't: a stable uid is what makes the provisioner update the
   dashboard in place instead of duplicating it, and a fresh export
   can come back with a different one.
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
2. Export the JSON Model and paste it into
   `modules/<host dir>/grafana-dashboards/<name>.json`. If the export
   has no uid (a bare v2 `spec` for a file with no git history), wrap
   it as `{"metadata": {"name": "<kebab-case-uid>"}, "spec": …}`.
   Then run `just dashboard` on that path.
3. Add a `dashboardsDir` entry named `"<Folder>/<name>.json"` with
   `path = ./grafana-dashboards/<name>.json`, plus a comment saying
   why it's hand-written (convention: the existing entries all explain
   themselves).
4. Deploy, confirm the provisioned copy renders, then delete the
   database copy you built in step 1 so there aren't two.
