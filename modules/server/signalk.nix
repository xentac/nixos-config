# Signal K: the boat's data hub (docs/adr/0005 — the one container on
# this host). Its only input is victron-signalk, the Signal K built into
# the Victron GX, pulled over the LAN as a Signal K-to-Signal K
# connection; its only sink is VictoriaMetrics (monitoring.nix scrapes
# /signalk/v1/api/prometheus). Node-RED runs *inside* it, as the
# @signalk/signalk-node-red plugin from the Appstore — there is no
# separate Node-RED service.
#
# Upstream ships only an npm package and this image; nixpkgs has
# nothing. The image tag below IS the server version: bumping it is a
# commit + deploy, nothing auto-updates. Plugins and webapps are
# installed by the server itself (npm into the state dir) through the
# Appstore, exactly as on the docker VM; the Admin UI's "Update Server"
# button is disabled by the image.
#
# Host networking (not a port map) because LAN apps find the server via
# the mDNS record it advertises itself, which needs the host's
# interfaces. 3000 on the LAN is deliberate: boat apps don't have
# tailscale. caddy.nix also publishes it as the tailnet name "signalk".
{ config, lib, ... }:
let
  version = "2.33.0";
  inherit (config.alba.signalk) port;
  stateDir = "/var/lib/signalk";
  npmCache = "/var/cache/signalk/npm";
  # The image runs as its `node` user (uid 1000 = xentac on this host),
  # so the container is told to run as a dedicated host user instead.
  # Static uid: the run command needs a number, and the image has no
  # passwd entry for it. Above NixOS's ascending dynamic range so it
  # can't collide with an auto-allocated system user.
  uid = 980;
in
{
  # For caddy.nix and monitoring.nix. Read-only: nothing passes it to
  # the server, this is just the port it listens on by default.
  options.alba.signalk.port = lib.mkOption {
    type = lib.types.port;
    default = 3000; # the default every Signal K client assumes; grafana moved to 3001 for it
    readOnly = true;
  };

  config = {
    users.users.signalk = {
      isSystemUser = true;
      group = "signalk";
      inherit uid;
    };
    users.groups.signalk.gid = uid;

    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = "podman";

    virtualisation.oci-containers.containers.signalk = {
      image = "signalk/signalk-server:v${version}";
      serviceName = "signalk"; # signalk.service, like every other service here
      user = "${toString uid}:${toString uid}";
      networks = [ "host" ];
      volumes = [
        "${stateDir}:/home/node/.signalk"
        # npm's cache would otherwise land in the image's /home/node/.npm,
        # which our uid can't write. /var/cache is outside the backup
        # snapshot.
        "${npmCache}:/home/node/.npm"
      ];
      environment = {
        # No passwd entry for our uid in the container, so node would
        # resolve the home dir to "/"; the server derives ~/.signalk from it.
        HOME = "/home/node";
      };
      extraOptions = [
        # Upstream's own run command uses it (zombie reaping for the npm
        # children the Appstore spawns).
        "--init"
        # The image's /home/node is 0750 node:node, so a foreign uid can't
        # even reach the entrypoint ("catatonit: failed to exec pid1:
        # Permission denied"). Supplementary gid 1000 = the image's `node`
        # group, enough to traverse; files we write are still 980:980.
        "--group-add=1000"
      ];
      # Pinned tag: "missing" means a new tag pulls once, and nothing else
      # ever does.
      pull = "missing";
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 signalk signalk -"
      "d ${npmCache} 0750 signalk signalk -"
    ];

    # Boat rule: nothing here waits on vault or on victron-signalk — the
    # server reconnects to its upstream on its own. The generated unit
    # already orders after network-online (it may need to pull).
    #
    # The Admin UI's Restart button (needed after every plugin install)
    # simply exits the process — exit 0, which the module's default
    # on-failure would leave dead. Docker's unless-stopped is what upstream
    # assumes; always is its systemd equivalent.
    systemd.services.signalk.serviceConfig.Restart = lib.mkForce "always";

    networking.firewall.allowedTCPPorts = [ port ];
    networking.firewall.allowedUDPPorts = [ 5353 ]; # mDNS advertisement
  };
}
