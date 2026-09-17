# modules/server/config-history.nix — journal mutable service configs.
#
# The services here keep config the app itself can rewrite at runtime
# (sab's ini, the arrs' config.xml). We want UI-editability without
# silently drifting from the nix config, so every change to a watched
# file is committed to a root-only git repo on the host. Each service
# start also drops a "baseline" commit (for sabnzbd that's the moment
# its preStart merge re-normalizes the ini from `settings`), so
#
#   config-drift [service...]
#
# shows exactly the runtime/UI edits made since nix last had its say —
# ready to fold back into media.nix. Full history: `git -C
# /var/lib/config-history log -p`. The repo holds credentials (api
# keys, server passwords), the same ones as the state dirs it mirrors;
# it is root-only (0700) and must never leave the host.
{ lib, pkgs, ... }:
let
  repoDir = "/var/lib/config-history";

  # service name -> the mutable config file the app may rewrite.
  # The arrs' config.xml is only bootstrap (port/api key/auth mode);
  # their real config lives in sqlite and is covered by their built-in
  # scheduled Backups instead — a binary db has no useful git diff.
  watched = {
    sabnzbd = "/var/lib/sabnzbd/sabnzbd.ini";
    sonarr = "/var/lib/sonarr/.config/NzbDrone/config.xml";
    radarr = "/var/lib/radarr/.config/Radarr/config.xml";
    whisparr = "/var/lib/whisparr/.config/Whisparr/config.xml";
  };

  commit = pkgs.writeShellApplication {
    name = "config-history-commit";
    runtimeInputs = [
      pkgs.git
      pkgs.util-linux
    ];
    text = ''
      # usage: config-history-commit <service> <file> <message>
      svc=$1
      src=$2
      msg=$3
      repo=${repoDir}

      # All services share one repo and restart together on a rebuild;
      # unserialized commits race on git's index.lock.
      exec 9>"$repo/.lock"
      flock 9

      if [ ! -d "$repo/.git" ]; then
        git -C "$repo" init -q
        git -C "$repo" config user.name "config-history"
        git -C "$repo" config user.email "root@localhost"
      fi

      # First boot: the app may not have written its config yet.
      [ -e "$src" ] || exit 0

      mkdir -p "$repo/$svc"
      install -m 600 "$src" "$repo/$svc/$(basename "$src")"
      git -C "$repo" add -A -- "$svc"

      case "$msg" in
        baseline*)
          # Baselines must exist even when the content commit already
          # landed (the path unit races ExecStartPost at service start):
          # config-drift diffs against the newest baseline.
          git -C "$repo" commit -q --allow-empty -m "$svc: $msg"
          ;;
        *)
          if git -C "$repo" diff --cached --quiet -- "$svc"; then
            exit 0
          fi
          git -C "$repo" commit -q -m "$svc: $msg"
          ;;
      esac
    '';
  };

  drift = pkgs.writeShellApplication {
    name = "config-drift";
    runtimeInputs = [ pkgs.git ];
    text = ''
      # Runtime/UI config edits since each service's last start.
      repo=${repoDir}
      [ $# -gt 0 ] || set -- ${lib.concatStringsSep " " (lib.attrNames watched)}
      for svc in "$@"; do
        base=$(git -C "$repo" log -n1 --format=%H --grep "^$svc: baseline" 2>/dev/null || true)
        echo "=== $svc ==="
        if [ -z "$base" ]; then
          # No baseline yet — show everything ever journaled.
          git -C "$repo" log --reverse -p -- "$svc"
        else
          git -C "$repo" diff "$base" HEAD -- "$svc"
        fi
      done
    '';
  };
in
{
  environment.systemPackages = [ drift ];

  systemd.tmpfiles.rules = [ "d ${repoDir} 0700 root root -" ];

  # One watcher per service; PathChanged fires on close-after-write.
  systemd.paths = lib.mapAttrs' (
    svc: file:
    lib.nameValuePair "config-history-${svc}" {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = file;
    }
  ) watched;

  systemd.services =
    lib.mapAttrs' (
      svc: file:
      lib.nameValuePair "config-history-${svc}" {
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe commit} ${svc} ${file} 'runtime change'";
        };
      }
    ) watched
    # Baseline commit on every service start ("+" = run as root since the
    # repo is root-only; "-" = a journaling failure must never fail the
    # service itself, which would make deploy-rs roll back the whole deploy).
    // lib.mapAttrs (svc: file: {
      serviceConfig.ExecStartPost = "-+${lib.getExe commit} ${svc} ${file} 'baseline (service start)'";
    }) watched;
}
