# MCP servers for Claude Code

Which MCP servers Claude Code has on donatello, how they're wired up, and
how to add one. Packages live in `modules/desktop/mcp.nix`; the
*registrations* live in `~/.claude.json` (user scope), which is not
declarative. A rebuilt machine needs the `claude mcp add` commands below
re-run.

## What's installed

| Name | Command | Access | Credential |
|------|---------|--------|------------|
| `grafana-alba` | `mcp-grafana-alba` (wrapper around `mcp-grafana`) | alba-nix's Grafana over the tailnet, read-only | `alba-grafana/mcp_token` in `secrets/donatello.yaml` |
| `nixos` | `mcp-nixos` | search.nixos.org, NixHub, FlakeHub, wiki, nix.dev, cache.nixos.org | none |
| claude.ai Claude Docs | cloud connector | Claude Docs | the claude.ai account; not managed here |

Register (or re-register) the ones from this repo:

```sh
claude mcp add -s user grafana-alba -- mcp-grafana-alba
claude mcp add -s user nixos -- mcp-nixos
claude mcp list            # each should say ✔ Connected
```

## The pattern

- **Packages come from Nix**, installed system-wide by `mcp.nix`. A
  registration names the bare command, never a `/nix/store` path, so it
  keeps working across rebuilds.
- **A credential never sits in `~/.claude.json`.** A server that needs one
  is a `writeShellApplication` wrapper that reads the secret from sops at
  exec time, exports it, and `exec`s the real server. The secret is owned
  by `xentac`, the user who runs Claude Code.
- **Read-only first.** Give the token the smallest role available, *and*
  pass the server's own read-only flag (`--disable-write` for Grafana),
  so a role that grows later doesn't quietly grant writes.
- **Write tools prompt.** Read-only tools may be allowlisted in Claude
  Code settings (`mcp__<name>__<tool>`); anything that changes state
  should keep asking.
- **Credentials stay on donatello.** Never hand alba-nix a credential so
  that an MCP can reach it (see the push-not-credentials monitoring
  design). Acting on alba-nix is meant to go through the curated alba-mcp
  (#20), not SSH or broad tokens.

## Adding one

1. Package it: `pkgs.<name>` if nixpkgs has it (check with the `nixos`
   MCP), else package it in the flake.
2. If it needs a credential, add it to `secrets/donatello.yaml`, declare
   `sops.secrets."<path>".owner = "xentac"` and wrap the server as
   `mcp-grafana-alba` does. Otherwise add the package directly.
3. Add it to `environment.systemPackages` in `mcp.nix` with a comment on
   what it reaches and why it's safe. Run `just check`, then `just switch`.
4. Smoke-test the binary over stdio before registering it:

   ```sh
   printf '%s\n' \
     '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
     '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
     '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
     | timeout 20 <command>
   ```

5. `claude mcp add -s user <name> -- <command>`, restart Claude Code,
   and add a row to the table above.

A server only one project needs goes in that repo's `.mcp.json`
(`claude mcp add -s project ...`) instead. The package still comes from
here.

## Using them

**grafana-alba.** Metrics work through the VictoriaMetrics datasource
(PromQL/MetricsQL), and so do dashboards, alert rules and annotations.
The log tools are Loki-only, so **VictoriaLogs isn't reachable** through
it. The VictoriaLogs MCP in #19 would fill that gap.

To recreate the token: in alba-grafana, Administration → Service accounts
→ `claude-mcp` (role **Viewer**) → add a token. Put the bare `glsa_...`
value in `sops secrets/donatello.yaml` under `alba-grafana/mcp_token`,
then `just switch`.

**nixos.** Use it for package names, option names and types, and home-manager
options, rather than recalling them. Caveat: it only indexes the channels
search.nixos.org has (today `25.11` as "stable" and `unstable`), **not
26.05**, which is what this flake pins. Query `unstable` (26.05 branched
from it, so it's the closer of the two) and treat the answer as a lead.
The ground truth is the pinned tree:

```sh
nix eval .#nixosConfigurations.donatello.options.<option.path>.type.description
nix eval --raw .#nixosConfigurations.donatello.pkgs.<pkg>.version
just check
```

## Troubleshooting

- `claude mcp list` shows the health of each server. `✘ Failed` with a
  wrapper usually means the sops secret didn't decrypt (check
  `/run/secrets/...` exists and is owned by xentac) or the command isn't
  on PATH yet (`just switch` not run).
- Run the stdio smoke test above against the wrapper to see the server's
  own error output.
- grafana-alba needs the tailnet: `tailscale status`, and
  `curl -sI https://alba-grafana.stalk-darter.ts.net`.

## Candidates

For this repo's machines and services: #19 (with alba-mcp specified in
#20). For the other repos, so each can get its own issue:

**Across all code repos**
- **Context7.** Version-accurate library docs for the fast-moving
  dependencies: axum, sqlx, React 19, Vite 7, vitest 4, Next.js. The free
  tier is a monthly request cap (reportedly 1,000 since Jan 2026), and
  each lookup takes two calls. Queries (library names and questions, not
  code) go to Upstash. Worth a trial. Prune it if it rarely gets called.
- **Torn API and FF Scouter API** (probably needs writing; shared by every
  Torn repo). These complement the `torn-city` and `torn-ffscouter`
  skills, they don't replace them: the skills carry the rules,
  mechanics and API semantics; an MCP would add live calls with the key
  held behind a sops wrapper (never in the transcript or argv),
  client-side rate limiting, and responses trimmed before they reach
  context. Both publish OpenAPI specs (snapshotted in `xentac/skills`), so
  a thin generated server is plausible. API data only: the skills'
  never-drive-torn.com rule still applies.

**torn_war_stuff_enhanced_server** (Rust/axum, valkey, k3s)
- **kubernetes-mcp-server** (`containers/kubernetes-mcp-server`,
  read-only). Pods, events and logs on the cluster. Sealed secrets stay
  sealed.
- **A second Grafana MCP** against the cluster's Grafana. That stack is
  Loki-based, so its log tools work there (unlike on alba). Same wrapper
  pattern, new Viewer service account.
- **Redis/Valkey MCP** (`redis/mcp-redis`, read-only, against a dev or
  port-forwarded instance). Inspect what the cache actually holds per
  faction.
- **Hetzner Cloud MCP**, once the multinode cluster lands: servers,
  firewalls, volumes.

**torn_war_monitor** (Rust/sqlx, Postgres + TimescaleDB, React/Vite)
- **postgres-mcp** (`crystaldba/postgres-mcp`, restricted mode, dev DB).
  Query plans, index advice, hypertable inspection.
- Shares the kubernetes and Grafana servers above once it moves to k3s.

**faction-compare** (Next.js 15, static export)
- **next-devtools-mcp** (Vercel) reads a running `next dev`'s build,
  runtime and type errors, logs and route metadata. It needs Next.js 16,
  so not until an upgrade.

**torn_war_stuff_enhanced, ffscouter** (React/Vite userscripts)
- Nothing beyond Context7 and the Torn/FF Scouter servers. No browser
  automation on torn.com (see the `torn-city` skill).

**Considered and set aside**
- **beancount:** Plaid (free Trial: 10 production Items with Transactions
  and Statements; SimpleFIN Bridge, ~$15/yr, is the transactions-only
  fallback) belongs in the ingest pipeline as an importer, not as an MCP.
  It means revisiting that repo's ADR 0004, since a stored access token is
  the credential it declined. Querying the ledger is `bean-query` plus a
  skill.
- **Obsidian:** Readwise Reader stays on the readwise-official plugin. A
  Google Calendar connector wouldn't get used.
- **Paperless** (#19): it waits on a habit of filing receipts there.

**droplet1-compose**
- **DigitalOcean MCP** (`digitalocean-labs/mcp-digitalocean`, read-only
  token) if the droplet sees active work. Otherwise nothing.

**Deliberately none:** `skills`, chezmoi dotfiles, `reallybad.ninja`,
`torn_scripts`, the annex repos, and **catastrophe**, which no MCP or
agent tooling should ever touch.
