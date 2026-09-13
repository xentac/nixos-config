# The media-automation stack, as native NixOS services (no containers —
# see docs/adr/0001). Two permission domains:
#
# (lib is used for mkForce on UMask below: the servarr modules hardcode
# a 0022 UMask we need to override for the shared /downloads tree.)
#
#   media  — sabnzbd, sonarr, radarr, whisparr: share /downloads and the
#            /Videos mount (mounts.nix forces gid=media there).
#   adult  — whisparr, stash: the only members, and therefore the only
#            users able to traverse the /adult mount (gid=adult, 0770).
#
# The library mounts are git-annex working trees owned by vault; these
# services just read/write plain files over SMB and vault's scheduled job
# annexes new arrivals (docs/adr/0002). Web exposure is caddy.nix's job:
# everything here binds localhost and is published under a tailnet name;
# stash and whisparr are tailnet-ONLY (kid-proofing).
{ config, lib, ... }:
{
  users.groups.media = { };
  users.groups.adult = { };

  # /downloads is its own btrfs subvolume (disko); make it group-writable
  # scratch shared by sab + arrs. setgid so everything created inside
  # inherits the media group. Contents are temporary by definition: a
  # download is done when it's been integrated into the annex on vault.
  systemd.tmpfiles.rules = [ "d /downloads 2775 root media -" ];

  # sab, sonarr, radarr stay reachable on LAN + tailnet (each has its own
  # auth: sab API key/login, arrs forms auth from the migrated configs).
  # caddy.nix additionally publishes each under a friendly tailnet name.
  services.sabnzbd = {
    enable = true;
    group = "media";
    openFirewall = true; # opens settings.misc.port (8080)
    # State (incl. sabnzbd.ini with API keys and server passwords) lives in
    # /var/lib/sabnzbd, migrated from baxter — see docs/alba-nix.md. The
    # module merges declarative settings into that ini at startup.
  };

  services.sonarr = {
    enable = true;
    group = "media";
    openFirewall = true; # 8989
  };

  services.radarr = {
    enable = true;
    group = "media";
    openFirewall = true; # 7878
  };

  services.whisparr = {
    enable = true;
    group = "media"; # /downloads access; adult via extraGroups below
    settings.server.bindaddress = "127.0.0.1"; # tailnet-only via caddy; never LAN
  };
  users.users.whisparr.extraGroups = [ "adult" ];

  # sab must bind LAN-reachable (it has its own API-key auth); the arrs
  # keep forms auth from the migrated configs. UMask so files written to
  # /downloads stay group-writable for the next service in the pipeline.
  systemd.services.sabnzbd.serviceConfig.UMask = lib.mkForce "0002";
  systemd.services.sonarr.serviceConfig.UMask = lib.mkForce "0002";
  systemd.services.radarr.serviceConfig.UMask = lib.mkForce "0002";
  systemd.services.whisparr.serviceConfig.UMask = lib.mkForce "0002";

  sops.secrets."stash/password" = {
    owner = "stash";
  };
  sops.secrets."stash/jwt_secret" = {
    owner = "stash";
  };
  sops.secrets."stash/session_key" = {
    owner = "stash";
  };

  services.stash = {
    enable = true;
    group = "adult";
    # Built-in auth is mandatory here (kid-proofing layer 4): username +
    # password required even on the tailnet.
    username = "xentac";
    passwordFile = config.sops.secrets."stash/password".path;
    jwtSecretKeyFile = config.sops.secrets."stash/jwt_secret".path;
    sessionStoreKeyFile = config.sops.secrets."stash/session_key".path;
    settings = {
      host = "127.0.0.1"; # tailnet-only via caddy; never LAN
      port = 9999;
      stash = [ { path = "/adult"; } ];
      # database/generated/cache default to /var/lib/stash/*; backups.nix
      # excludes generated+cache (regenerable) from restic.
    };
  };
}
