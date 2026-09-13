# The media libraries on vault (the Synology NAS), mounted over SMB at the
# same absolute paths the old container stack used (/Videos, /adult) so the
# migrated arr databases keep working without path surgery.
#
# Both trees are locked git-annex working trees owned by vault: annexed
# files arrive over SMB as read-only "real" files (the Synology serves the
# annex symlinks resolved), new imports are plain files until vault's
# scheduled job annexes them (docs/adr/0002). Nothing here knows about
# git-annex, on purpose.
#
# CIFS has no real unix owners: the uid/gid/*_mode options below are
# synthetic, client-side permissions — which is exactly what makes the
# permission model airtight. /Videos is readable by everyone, writable by
# group media. /adult is invisible to anyone outside group adult
# (kid-proofing layer 2); layer 1 is the share's own ACL on vault, which
# only the dedicated service account (whose credentials are in sops) and
# xentac can open.
{ config, pkgs, ... }:
let
  vault = "192.168.1.223";

  # An SMB credentials file (username=/password= lines) for the dedicated
  # NAS service account — never xentac's own account.
  credentials = config.sops.secrets."vault/smb-credentials".path;

  common = [
    "credentials=${credentials}"
    "vers=3.1.1"
    "soft" # fail I/O with an error if vault is gone, don't hang forever
    # Boot must not block on the NAS (boat rule): mount on first access
    # instead, and give up quickly when vault is unreachable.
    "nofail"
    "_netdev"
    "x-systemd.automount"
    "x-systemd.mount-timeout=30s"
    "x-systemd.idle-timeout=0"
  ];
in
{
  sops.secrets."vault/smb-credentials" = { };

  environment.systemPackages = [ pkgs.cifs-utils ];

  fileSystems."/Videos" = {
    device = "//${vault}/media/Videos";
    fsType = "cifs";
    options = common ++ [
      "gid=media"
      "file_mode=0664"
      "dir_mode=0775"
    ];
  };

  fileSystems."/adult" = {
    device = "//${vault}/adult";
    fsType = "cifs";
    options = common ++ [
      "gid=adult"
      # Group rw so whisparr and stash can write; NO access for "other".
      "file_mode=0660"
      "dir_mode=0770"
    ];
  };
}
