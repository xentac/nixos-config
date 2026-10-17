# 0006 — Two Whisparr instances: scenes (v2) and movies (v3)

Date: 2026-10-17. Status: accepted.

## Context

Whisparr v2 is a Sonarr fork: a site is a series, a scene an episode.
That model is the one wanted for sites, but it cannot represent a
full-length movie at all. Radarr can't fill the gap: its metadata source
is the Servarr-hosted TMDB proxy, hardcoded, and TMDB excludes most
adult titles. Whisparr v3 ("Eros") is the Radarr fork that swaps that
backend for StashDB/TPDB and does movies (and scenes, as standalone
items). nixpkgs packages both, as `whisparr_2` and `whisparr_3`.

Alternatives: (a) replace v2 with v3 — one instance, but v3's scene
handling is not the site-as-series model, and v2's DB doesn't migrate;
(b) grab movies by hand — no automation; (c) Radarr pointed at TPDB —
only by faking its metadata API, rejected.

## Decision

Run both, with disjoint jobs:

- **whisparr-scenes** (v2) tracks sites/scenes, root `/adult/scenes`,
  sab category `adult-scenes`.
- **whisparr-movies** (v3) tracks movies only, root `/adult/movies`, sab
  category `adult-movies`. Never add a studio or performer there: that
  would monitor their scenes and duplicate whisparr-scenes. A usage
  rule, not enforced.

Both are built by one local module (`modules/server/whisparr.nix`)
instead of `services.whisparr`, which is single-instance with a fixed
unit name. The v2 instance was renamed from `whisparr` for symmetry,
and `/adult` was restructured from `<site>/` to `scenes/<site>/` so
the two roots are siblings. Both stay in the one annex-backed library:
no new share, annex repo or stash library path.

## Consequences

- Maintenance: the local module is a short unit/user/tmpfiles builder;
  nixpkgs' `servarr/settings-options.nix` is imported, not copied, so
  the env-var logic tracks upstream. Package bumps come with flake
  updates like every other service.
- Each instance has its own indexers (no Prowlarr; revisit in phase 2
  when torrent indexers arrive) and its own UI config in its DB.
- stash identifies movies via a second stash-box (TPDB); StashDB is
  scene-centric and will often not match a movie.
- Exit: if v3's scene handling becomes good enough, migrate sites into
  whisparr-movies (re-adding them; v2's DB doesn't convert), delete the
  scenes instance and drop the `adult-scenes` category. The `/adult`
  layout already supports either end state.
