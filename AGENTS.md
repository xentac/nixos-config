# Agent notes

NixOS flake for Jason's machines: `hosts/donatello` (laptop) and
`hosts/alba-nix` (boat-services VM). `CONTEXT.md` is the glossary,
`docs/adr/` holds the design decisions, `docs/alba-nix.md` the server
runbook. Deploy: `just switch` (donatello, local) and `just deploy alba-nix`
(deploy-rs over SSH). Never SSH into a remote host unless asked.

## Agent skills

### Issue tracker

Issues are tracked on GitHub (`xentac/nixos-config`) via the `gh` CLI; external PRs are not pulled into the triage queue. See `docs/agents/issue-tracker.md`.

### Triage labels

Default label vocabulary — `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout — `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
