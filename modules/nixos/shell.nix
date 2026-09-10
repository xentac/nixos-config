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
    pkgs.dig
  ];

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
