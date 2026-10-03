# A read-only fava over the finance ledger (github.com/xentac/beancount).
#
# The laptop is the ledger's only writer (its ingest pipeline and
# navigator edit and commit there); this host just mirrors what has been
# pushed. A timer pulls main into a checkout, and fava serves it with
# --read-only, so nothing here can diverge from git. Fava re-reads the
# files on its own when they change — no restart on sync.
#
# The checkout lives under /var/cache, not /var/lib: it is a derived copy
# of a GitHub repo, so backups.nix's /var/lib snapshot never sees it.
#
# Binds localhost; caddy.nix publishes it as the tailnet name "fava".
# Fava has no login of its own, so the tailnet ACL is the only gate:
# deny every device that isn't Jason's the `fava` node (same mechanism
# as the kid-proofing on `stash`).
#
# nixpkgs' fava/beancount trail the project's pins by a patch release or
# two; the ledger only uses beancount's built-in plugins and no fava
# extensions, so nothing from the project's own venv is needed.
{ config, pkgs, ... }:
let
  repo = "git@github.com:xentac/beancount.git";
  branch = "main";
  checkout = "/var/cache/fava/ledger";
  ledger = "${checkout}/data/finances.beancount";
  port = 5000;
in
{
  # Read-only deploy key for the (private) ledger repo. Generate with
  #   ssh-keygen -t ed25519 -N "" -C alba-nix-fava -f fava_deploy
  # add fava_deploy.pub under the repo's Settings > Deploy keys (leave
  # "Allow write access" off), and paste the private key as
  #   fava:
  #     deploy_key: |
  #       -----BEGIN OPENSSH PRIVATE KEY-----
  #       ...
  # in secrets/alba-nix.yaml.
  sops.secrets."fava/deploy_key".owner = "fava";

  # Pin GitHub's host key system-wide so the first clone doesn't need an
  # interactive trust decision (the fava user has no home or known_hosts).
  # From https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
  programs.ssh.knownHosts.github = {
    hostNames = [ "github.com" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
  };

  users.users.fava = {
    isSystemUser = true;
    group = "fava";
  };
  users.groups.fava = { };

  # Mirror the ledger: shallow clone once, then fetch + hard reset. A
  # reset (not a pull) means a force-push upstream can't wedge it.
  # Untracked files survive the reset, which is what we want: beancount's
  # .picklecache next to the ledger is what keeps a 25k-line load fast.
  systemd.services.fava-sync = {
    description = "Pull the finance ledger for fava";
    startAt = "*:0/15";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.git
      pkgs.openssh
    ];
    environment.GIT_SSH_COMMAND = "ssh -i ${
      config.sops.secrets."fava/deploy_key".path
    } -o IdentitiesOnly=yes";
    script = ''
      if [ -d ${checkout}/.git ]; then
        git -C ${checkout} fetch --quiet --depth 1 origin ${branch}
        git -C ${checkout} reset --quiet --hard FETCH_HEAD
      else
        git clone --quiet --depth 1 --branch ${branch} ${repo} ${checkout}
      fi
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "fava";
      Group = "fava";
      CacheDirectory = "fava"; # creates /var/cache/fava owned by fava
    };
  };

  systemd.services.fava = {
    description = "fava (read-only) over the finance ledger";
    wantedBy = [ "multi-user.target" ];
    # Fava refuses to start without the ledger file, so the first boot
    # needs the clone first; on later boots the sync is a quick no-op.
    # Restart covers the sync failing (no internet yet) on a fresh host.
    wants = [ "fava-sync.service" ];
    after = [ "fava-sync.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.fava}/bin/fava --read-only --host 127.0.0.1 --port ${toString port} ${ledger}";
      User = "fava";
      Group = "fava";
      CacheDirectory = "fava";
      Restart = "on-failure";
      RestartSec = "30s";

      # Nothing on this host besides the checkout is fava's business.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
    };
  };
}
