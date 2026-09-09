# Fonts. Your kitty config asks for "Inconsolata Me" (not installed anywhere
# on the current machine either — kitty was silently falling back). Waybar
# uses FontAwesome + Nerd Font symbols; sway titles use FontAwesome/Terminus.
{ pkgs, ... }:
{
  fonts.packages = with pkgs; [
    inconsolata
    nerd-fonts.inconsolata
    nerd-fonts.symbols-only # SymbolsNerdFont, what waybar's icons use
    terminus_font
    terminus_font_ttf
    font-awesome
    fira-code
    roboto
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
    liberation_ttf
    dejavu_fonts
  ];
  fonts.fontconfig.defaultFonts = {
    monospace = [
      "Inconsolata Nerd Font"
      "Inconsolata"
    ];
    sansSerif = [
      "Roboto"
      "Noto Sans"
    ];
    emoji = [ "Noto Color Emoji" ];
  };
}
