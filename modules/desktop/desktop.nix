# Sway (Wayland) desktop, matching your current Ubuntu setup: GDM -> sway,
# waybar, mako, rofi, swaylock/swayidle, grim/slurp screenshots, kanshi.
{ pkgs, ... }:
{
  # Enabling sway at the SYSTEM level (not just installing the package)
  # matters: it registers the PAM service swaylock needs to unlock, sets up
  # the wlroots xdg portal, and adds the session to GDM's chooser.
  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true; # GTK apps get proper Wayland settings
    extraPackages = with pkgs; [
      swaylock
      swayidle
      waybar
      mako
      kanshi # output profiles (your sway config execs it)
      rofi # in 26.05 rofi is the Wayland-capable build
      rofimoji
      bemenu # bound to XF86Search in your sway config
      grim
      slurp
      wl-clipboard
      brightnessctl
      playerctl
      wdisplays
      jq # used by your screenshot/keyboard bindings
      xdg-utils
    ];
  };

  # Login manager. GDM works fine with sway and unlocks gnome-keyring at
  # login (Chrome/Slack/etc store secrets there). Alternative: greetd + tuigreet.
  services.displayManager.gdm.enable = true;
  # Without an explicit default, GDM's fallback picks its internal
  # gnome-greeter session (Exec=gnome-session) and login fails.
  services.displayManager.defaultSession = "sway";
  services.xserver.enable = true; # also makes services.xserver.xkb apply to GDM
  services.xserver.excludePackages = [ pkgs.xterm ];

  # Screen sharing / file pickers for Wayland apps.
  xdg.portal = {
    enable = true;
    wlr.enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };

  services.gnome.gnome-keyring.enable = true;
  programs.dconf.enable = true; # GTK settings persistence

  # Thunar + plugins, thumbnails, automount.
  programs.thunar = {
    enable = true;
    plugins = with pkgs; [
      thunar-archive-plugin
      thunar-volman
    ];
  };
  services.tumbler.enable = true;
  services.udisks2.enable = true;

  # Chrome/Electron apps (Slack, Discord, Obsidian, Signal) run native
  # Wayland instead of XWayland.
  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  # Cursor theme/size for every app. Without these the 2x-scaled Framework
  # panel gets a tiny (and sometimes janky, software-rendered) cursor.
  # Size is LOGICAL pixels: sway multiplies by output scale when rendering.
  # The sway config has a matching `seat * xcursor_theme Adwaita 24` rule.
  environment.sessionVariables.XCURSOR_THEME = "Adwaita";
  environment.sessionVariables.XCURSOR_SIZE = "24";

  # brightnessctl without sudo (installs udev rules; user is in "video").
  services.udev.packages = [ pkgs.brightnessctl ];

  environment.systemPackages = with pkgs; [
    networkmanagerapplet # nm-applet, exec'd from your sway config
    pavucontrol
    libnotify # notify-send
    kitty # your terminal (no more ~/.local/kitty.app)
    argyllcms # dispwin, if you re-calibrate the new panel
    seahorse
  ];
}
