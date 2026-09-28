# Zsh as the interactive shell, with a starship prompt.
#
# Deliberately minimal: this module only enables machinery (packages, plugins,
# prompt init, history). Aliases, functions, and starship.toml live in
# chezmoi-managed dotfiles — zsh reads /etc/zshrc (this config) before
# ~/.zshrc, and starship prefers ~/.config/starship.toml when it exists.
{ pkgs, ... }:
{
  # Unified git+jj prompt module, wired up via [custom.jj] in starship.toml.
  environment.systemPackages = [
    pkgs.jj-starship
  ];

  # Every host needs an editor, including headless servers where root at a
  # rescue console may be the only login. defaultEditor sets EDITOR/VISUAL
  # system-wide so sudoedit, systemctl edit, git, etc. pick it up.
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
  };

  # Terminfo for terminals that aren't installed here (kitty, ghostty, …), so
  # SSHing in from one doesn't leave TERM unresolvable ("can't find terminal
  # definition for xterm-kitty") and break zsh, less, etc.
  environment.enableAllTerminfo = true;

  programs.zsh = {
    enable = true; # registers zsh in /etc/shells; required for shell = pkgs.zsh
    autosuggestions.enable = true; # fish-style grey inline suggestions from history
    syntaxHighlighting.enable = true; # valid commands green, typos red, as you type
    histSize = 50000;
  };

  programs.starship = {
    enable = true; # adds `eval "$(starship init zsh)"` to interactive shells
    # settings intentionally empty: ~/.config/starship.toml (chezmoi) wins.
  };
}
