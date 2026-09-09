# Desktop applications. On Ubuntu these came from apt + snap + flatpak; on
# NixOS nearly all of them are in nixpkgs. Flatpak stays enabled for the
# handful that aren't (see README migration table).
{ pkgs, ... }:
{
  services.flatpak.enable = true; # `flatpak remote-add flathub ...` once

  # Ollama was installed but inactive on Ubuntu; keep it available, off by default.
  services.ollama.enable = false;

  users.users.xentac.packages = with pkgs; [
    # browsers
    google-chrome
    chromium
    firefox
    # comms
    thunderbird
    signal-desktop
    discord
    slack
    element-desktop
    zoom-us
    # notes / knowledge
    obsidian
    anki
    zotero
    # passwords
    keepassxc
    bitwarden-cli
    age
    gocryptfs
    # office / docs
    libreoffice-fresh
    evince
    mupdf
    xournalpp
    img2pdf
    poppler-utils
    calibre
    koreader
    # graphics / media
    gimp
    inkscape
    kicad
    vlc
    mpv
    obs-studio
    handbrake
    shotcut
    ffmpeg-full
    ffmpegthumbnailer
    yt-dlp
    exiftool
    # sailing / diving
    opencpn
    subsurface
    # sync / backup / remote
    rclone
    nextcloud-client
    rustdesk
    restic
    resticprofile
    # dev-adjacent GUI
    bruno
    wireshark
    # misc
    appimage-run # run OpenAudible / other AppImages: `appimage-run foo.AppImage`
    qdirstat
    xdot
    wine
    winetricks
  ];
}
