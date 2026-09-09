# Settings for the Nix package manager itself.
{ inputs, ... }:
{
  nix.settings = {
    # Flakes and the `nix <verb>` CLI are still opt-in in 26.05.
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # Hard-link identical files in /nix/store to save space.
    auto-optimise-store = true;
    # Lets your user add binary caches / run nix with elevated settings.
    trusted-users = [
      "root"
      "@wheel"
    ];
  };

  # Old generations are what let you roll back from the boot menu, but they
  # also pin every old package on disk. Auto-delete generations >30 days old.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Make ad-hoc commands (`nix shell nixpkgs#foo`, `nix-shell -p foo`) use the
  # SAME nixpkgs revision as the system, instead of downloading another copy.
  nix.registry.nixpkgs.flake = inputs.nixpkgs;
  nix.nixPath = [ "nixpkgs=${inputs.nixpkgs}" ];

  # Chrome, Zoom, Slack, Discord, Steam, Terraform... are unfree.
  nixpkgs.config.allowUnfree = true;
}
