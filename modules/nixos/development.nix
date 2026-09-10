# Compilers, language toolchains, LSP servers for LazyVim, CLI tooling.
#
# Big NixOS difference: nvm, Mason (LazyVim's LSP installer), cargo-binstall,
# and most "curl | sh" installers download prebuilt binaries that expect
# /lib64/ld-linux-x86-64.so.2 to exist. It doesn't on NixOS. Two fixes:
#   1. programs.nix-ld below fakes that loader so MANY prebuilt binaries just
#      work (claude, gcloud, cargo-binstall'd tools, nvm's node...).
#   2. Prefer installing tools from nixpkgs (below) and tell Mason to stop
#      auto-installing. See README "LazyVim on NixOS".
{ pkgs, ... }:
{
  programs.nix-ld.enable = true;

  # direnv + nix-direnv: `use flake` in a project's .envrc gives you a
  # per-project dev shell automatically. The idiomatic replacement for
  # global pip/npm installs.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  environment.systemPackages = with pkgs; [
    # --- VCS
    git
    git-annex
    git-filter-repo
    gh
    jujutsu
    lazygit
    tig
    git-lfs

    # --- editor / shell
    neovim
    tmux
    starship
    fzf
    ripgrep
    fd
    # jq comes from desktop.nix: sway's screenshot/keyboard bindings need it
    yq-go
    just
    tree
    bat
    eza
    delta
    htop
    btop
    ncdu
    gdu
    fastfetch
    wget
    curl
    unzip
    zip
    p7zip
    unrar
    file
    screen
    w3m
    wcalc

    # --- build tools (also needed: nvim-treesitter compiles parsers with cc)
    gcc
    gnumake
    cmake
    meson
    ninja
    pkg-config

    # --- languages
    nodejs
    pnpm
    bun
    go
    rustup # `rustup default stable` once; nixpkgs patches toolchains to work
    cargo-audit
    cargo-binstall
    python3
    uv # `uv tool install foo` replaces pipx (pipx's tests fail on 26.05, so it is not cached)
    openjdk21
    R

    # --- Nix itself (you'll be editing .nix files a lot at first)
    nil # Nix LSP
    nixfmt
    nix-tree # explore why something is in your closure
    nix-output-monitor

    # --- LSP / formatters / linters for your LazyVim extras (instead of Mason)
    lua-language-server
    stylua
    beancount-language-server
    terraform-ls
    markdownlint-cli2
    marksman
    gopls
    basedpyright
    ruff
    typescript-language-server
    typescript
    vscode-langservers-extracted # json/html/css/eslint servers
    yaml-language-server
    dockerfile-language-server
    ansible-language-server
    svelte-language-server
    tailwindcss-language-server
    taplo
    texlab
    biome
    prettier
    shfmt
    shellcheck
    tree-sitter

    # --- infra / cloud
    ansible
    terraform
    google-cloud-sdk
    doctl
    postgresql # psql client
    valkey # valkey-cli / redis-cli
    devcontainer

    # --- misc dev
    beancount
    fava
    android-tools
    claude-code
    gemini-cli
  ];
}
