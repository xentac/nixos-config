# 0005 — Signal K runs as a container (amending 0001)

Date: 2026-10-10. Status: accepted.

## Context

ADR 0001 put the media stack on native NixOS modules and kept container
runtimes off alba-nix: every one of those services had a first-class
nixpkgs module, so containers bought nothing. Signal K is the first
service to migrate off the docker VM without one: upstream ships an npm
package and an official image, nixpkgs has neither a package nor a
module (the package request was closed "not planned"), and there is no
community flake. The server releases roughly monthly.

Alternatives: (a) vendor it in `pkgs/` with `buildNpmPackage`, like
stash — pure and consistent with 0001, but every bump is a hash/native-
dependency chore owned here, and the result is no more declarative:
plugins are installed at runtime by the server itself, via npm into the
state dir, under either approach. (b) A unit that `npm install`s at
start — a container without the isolation, not reproducible, rejected.
Note that the image *disables* the Admin UI's "Update Server" button,
so the container is not a route to in-app server updates either; it is
only a cheaper bump.

## Decision

Signal K runs from the official `signalk/signalk-server` image under
`virtualisation.oci-containers` (podman), with the tag pinned in
`modules/server/signalk.nix`. Nix still owns everything around it: the
unit, the host user, the state dir and its backup, the firewall, the
config journal and the tailnet name. Node-RED is the embedded Signal K
plugin, not a service.

0001's rule becomes: native modules wherever nixpkgs has one; a
container is acceptable only when upstream ships nothing but npm/an
image and nixpkgs has nothing — and then it is pinned, and nothing
auto-updates.

## Consequences

- A server bump is a one-line tag change + deploy, and rolling back is
  the same line. Plugins/webapps keep updating through the Appstore,
  as on the docker VM.
- podman is now on the boat VM. Host networking is used (mDNS
  discovery by boat apps needs the host's interfaces), so the container
  provides packaging, not isolation; it runs as a dedicated host uid.
- The state dir (`/var/lib/signalk`, mounted as the image's
  `~/.signalk`) is as mutable as any other service's: restic covers it,
  config-history journals the config files in it. ADR 0004's "to be
  confirmed" for Signal K data is answered the same way — local disk.
- The in-app server update is dead by construction (image + Nix store);
  the UI still shows "new version available" as the prompt to bump.
- Precedent risk: the criterion above is what stops this from becoming
  "containers when convenient". Sonarr-class services stay native.
