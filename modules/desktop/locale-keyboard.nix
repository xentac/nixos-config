# Timezone, locale and — important for you — Dvorak EVERYWHERE.
#
# On Ubuntu the layout was set in one place. On NixOS there are three
# separate keyboard consumers and each needs telling, or you will type your
# LUKS passphrase / login password in Dvorak on a QWERTY map:
#   1. the initrd + virtual console (console.keyMap)
#   2. GDM's login screen (services.xserver.xkb)
#   3. sway itself (your chezmoi sway config: `xkb_layout custom`)
{ ... }:
{
  time.timeZone = "America/Los_Angeles";
  i18n.defaultLocale = "en_US.UTF-8";

  console = {
    keyMap = "dvorak";
    earlySetup = true; # apply the keymap in the initrd, before the LUKS prompt
  };

  services.xserver.xkb = {
    layout = "us";
    variant = "dvorak";
  };

  # Your custom layout (us(dvorak) + Caps -> grave/tilde) lives in
  # ~/.config/xkb/symbols/custom via chezmoi. libxkbcommon reads that
  # directory on every distro, so it keeps working on NixOS unchanged.
  # The old ~/.Xmodmap is X11-only and does nothing under sway.
}
