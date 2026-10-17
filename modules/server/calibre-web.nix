# calibre-web: browse, read and download the calibre library from any
# device. Native nixpkgs module, per docs/adr/0001; replaces the docker
# VM's container.
#
# The library is the /books mount (mounts.nix): vault's annex working
# tree of the calibre repo, mounted read-only. Books are single-writer —
# calibre on donatello edits, the git-annex assistant pushes to vault,
# vault's scheduled `git annex sync` brings its checkout up to date — so
# this instance must never write metadata.db or a book file. The ro mount
# enforces that; uploading and conversion are off so the UI doesn't offer
# what would only fail. Also untick "Edit"/"Upload"/"Delete" on every
# user in the admin UI (stored in app.db, not declarable here).
#
# State is app.db (users, shelves, read status, Kobo sync) under
# /var/lib/calibre-web, covered by backups.nix's /var/lib snapshot; the
# cover/thumbnail cache lives in /var/cache. Binds localhost; caddy.nix
# publishes it as the tailnet name "calibre-web". It keeps its own login.
{ lib, ... }:
{
  services.calibre-web = {
    enable = true;
    listen.ip = "127.0.0.1";
    options = {
      calibreLibrary = "/books";
      enableBookUploading = false;
      enableBookConversion = false;
    };
  };

  # The module adds the library to ReadWritePaths; with ProtectSystem=strict
  # dropping it leaves /books read-only inside the unit as well as at the
  # mount. (StateDirectory still makes /var/lib/calibre-web writable.)
  #
  # It's the only service here that can't start without vault (ExecStartPre
  # checks /books/metadata.db, which triggers the automount). Retry slowly
  # and forever instead of tripping the start limit, so it comes up on its
  # own once vault does (boat rule: no Requires= on the NAS mount).
  systemd.services.calibre-web = {
    serviceConfig = {
      ReadWritePaths = lib.mkForce [ ];
      RestartSec = "60s";
    };
    startLimitIntervalSec = 0;
  };
}
