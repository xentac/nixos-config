# 0001 — Media stack as native NixOS services, not containers

Date: 2026-09-13. Status: accepted.

## Context

The media stack (sabnzbd, sonarr, radarr, whisparr, stash) ran on baxter
as a docker compose stack of linuxserver/hotio images. Moving it to the
alba-nix VM, the obvious port was `virtualisation.oci-containers` with
the same images. The pinned nixpkgs (26.05) has first-class modules for
every one of these services.

## Decision

Run all of them as native NixOS services. No container runtime on
alba-nix in phase 1.

## Consequences

- The linuxserver PUID/PGID/UMASK contortions disappear: each service is
  a real systemd unit with a real dedicated user, and the root-owned
  volume problem from the compose era cannot recur.
- File permissions are handled with two ordinary unix groups (media,
  adult) instead of forced container uids.
- Trade-off: service versions ride nixpkgs instead of image tags. Rolling
  back a bad app update means rolling back the flake pin (or pinning one
  package), not re-tagging an image.
- Migration cost accepted: per-service state copy from the compose
  volumes into `/var/lib/<svc>` (documented in docs/alba-nix.md), since
  the on-disk layouts differ slightly from the linuxserver images.
