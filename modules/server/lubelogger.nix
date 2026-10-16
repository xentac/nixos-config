# LubeLogger: maintenance and fuel log for the road vehicles (and maybe,
# later, Alba's engines, which it can track by engine hours). Native
# nixpkgs module, per docs/adr/0001.
#
# State is one embedded LiteDB file plus uploaded documents under
# /var/lib/lubelogger, so backups.nix's /var/lib snapshot covers it with
# no extra config. Reminders are UI-only for now; email would be SMTP
# settings via services.lubelogger.environmentFile from a sops secret.
#
# Binds localhost; caddy.nix publishes it as the tailnet name
# "lubelogger". Its built-in login is left off, so the tailnet ACL is the
# only gate: allow only Jason's devices the `lubelogger` node (add his
# wife's when she starts using it). Turn on LubeLogger's own accounts in
# its UI if records ever need per-person attribution.
{ inputs, pkgs, ... }:
{
  services.lubelogger = {
    enable = true;
    # The package comes from nixpkgs-unstable: 26.05 is frozen at 1.7.0
    # while upstream releases roughly every two weeks and r-ryantm bumps
    # unstable within ~10 days. `nix flake update nixpkgs-unstable` picks up
    # new versions. The module itself stays the stable one.
    package = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.lubelogger;
    port = 5050; # module default 5000 is fava's
  };
}
