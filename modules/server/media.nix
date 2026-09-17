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
{
  config,
  lib,
  pkgs,
  ...
}:
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

    # Declarative-with-drift: on every start the module merges layers
    # (on-disk ini < `settings` < sops secrets) and rewrites the ini, so
    # every key declared here still wins after a restart. The file stays
    # writable in between (without this, sab retries its periodic
    # config save forever, spamming "Cannot write to INI file"). UI
    # edits to UNdeclared keys persist and are journaled by
    # config-history.nix; `config-drift sabnzbd` shows what to fold back
    # into `settings`. Transcribed from baxter's ini (deliberate
    # non-defaults only); credentials live in the sops fragment below.
    # Queue/history state stays in /var/lib/sabnzbd.
    allowConfigWrite = true;
    settings = {
      misc = {
        host = "::"; # LAN + localhost (caddy); sab has its own auth
        # Non-local clients (LAN, and the tailnet via caddy) get the
        # API and the web UI, both behind sab's own login.
        inet_exposure = "api+web (auth needed)";
        url_base = "/sabnzbd"; # the arrs' download-client configs use this path
        # sab's DNS-rebinding protection rejects Host headers that
        # aren't an IP or its own hostname; caddy forwards the tsnet
        # name verbatim.
        host_whitelist = "sabnzbd.stalk-darter.ts.net,alba-nix,";
        bandwidth_max = "60M";
        bandwidth_perc = 100;
        cache_limit = "1G";
        download_dir = "/downloads/incomplete";
        complete_dir = "/downloads/complete";
        direct_unpack = true;
        # unrar extracts files 0600 regardless of umask; without this the
        # arrs (same group, different user) can't import completed jobs.
        # sab chmods finished jobs: dirs 775, files 775 & 666 = 664.
        permissions = "775";
      };
      # username/password per server come from secretFiles.
      servers = {
        "NEWS.USENETSERVER.COM" = {
          name = "NEWS.USENETSERVER.COM";
          displayname = "NEWS.USENETSERVER.COM";
          host = "news.usenetserver.com";
          connections = 49;
        };
        "news.eweka.nl" = {
          name = "news.eweka.nl";
          displayname = "news.eweka.nl";
          host = "news.eweka.nl";
          connections = 47;
        };
        "news.newsdemon.com" = {
          name = "news.newsdemon.com";
          displayname = "news.newsdemon.com";
          host = "news.newsdemon.com";
          connections = 20;
          priority = 1;
        };
        "eunews.blocknews.net" = {
          name = "eunews.blocknews.net";
          displayname = "eunews.blocknews.net";
          host = "eunews.blocknews.net";
          connections = 49;
          priority = 1;
        };
      };
      # priority -100 = "Default" in the UI; the arrs pick their own.
      categories = {
        "*" = {
          name = "*";
          order = 0;
          pp = 2;
          priority = 0;
        };
        movies = {
          name = "movies";
          order = 1;
          priority = -100;
        };
        tv = {
          name = "tv";
          order = 2;
          priority = -100;
        };
        audio = {
          name = "audio";
          order = 3;
          priority = -100;
        };
        software = {
          name = "software";
          order = 4;
          priority = -100;
        };
        readarr = {
          name = "readarr";
          order = 5;
          priority = -100;
        };
        adult = {
          name = "adult";
          order = 6;
          priority = -100;
        };
      };
    };

    # api_key/nzb_key, web login, and per-server credentials: an ini
    # fragment merged over `settings` at service start (recursive
    # section merge, secrets win).
    secretFiles = [ config.sops.secrets."sabnzbd/secrets_ini".path ];
  };

  # preStart (which does the merge) runs as the service user.
  sops.secrets."sabnzbd/secrets_ini".owner = "sabnzbd";

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
    # baxter's stash DB is schema 85 (stash 0.31.x); nixpkgs is stuck on
    # 0.29.1 (schema 72) and stash can't downgrade. Vendored bump — see
    # pkgs/stash/package.nix for when it can be dropped.
    package = pkgs.callPackage ../../pkgs/stash/package.nix { };
    group = "adult";
    # Built-in auth is mandatory here (kid-proofing layer 4): username +
    # password required even on the tailnet.
    #
    # stash/password must hold a BCRYPT HASH, not the password: the module
    # copies the file into config.yml's `password` field verbatim, and
    # stash strictly bcrypt-compares login attempts against that field —
    # a plaintext value can never match (every login 401s). Generate with:
    #   nix run nixpkgs#whois -- mkpasswd -m bcrypt
    username = "xentac";
    passwordFile = config.sops.secrets."stash/password".path;
    # Default (true) means config.yml is generated ONCE and settings +
    # secrets are ignored forever after — a rotated password never takes
    # effect. false = regenerate each start, same declarative-with-drift
    # deal as sab: UI config edits are temporary, journaled by
    # config-history.nix, and get folded back into `settings` here.
    mutableSettings = false;
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
