# 0003 — caddy-tailscale as the service naming layer (replacing tsdproxy)

Date: 2026-09-13. Status: accepted (probationary — see risk).

## Context

Services have per-service tailnet hostnames today via tsdproxy on the
docker VM: magical (docker-label-driven) but one userspace tsnet node
*process* per service, with observed performance doubts. Wanted: keep
proper per-service tailnet names, with fewer moving parts. Alternatives
considered: a central reverse proxy + own-domain wildcard DNS to one
tailscale IP (fastest, but loses tailnet-native names and per-node
ACLs); `tailscale serve` (one hostname, port/path-based — rejected,
proper hostnames required).

## Decision

One Caddy process on alba-nix built with the caddy-tailscale plugin.
Each published service is a vhost bound to an embedded tsnet node with
its own tailnet hostname. Config is declarative in the flake
(`modules/server/caddy.nix`, one attrset entry per service — the
successor of tsdproxy's labels); the tsnet auth key lives in sops.

## Consequences

- Per-service tailnet nodes are preserved, so tailnet ACLs stay
  per-service — this is what makes kid-proofing layer 3 (deny kid
  devices the `stash`/`whisparr` nodes) clean.
- tsnet nodes are location-independent: this one Caddy can front
  backends on other hosts, so docker-VM services can migrate their
  names here before their processes move.
- Still userspace networking per node (tsnet), but one process total.
  If throughput ever matters for a service, give it a direct binding.
- **Risk**: caddy-tailscale is the youngest component in the design and
  effectively pre-release (pseudo-versioned). It is isolated in one
  module; the fallback (central caddy + wildcard DNS on an owned
  domain) changes only that module, not the services behind it.
- Each tsnet node consumes a tailnet device slot.
