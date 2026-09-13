# Your user account. The password is imperative state, set with `passwd`.
# Only the groups every host needs are here; desktop-only groups (docker,
# networkmanager, ...) are added in modules/desktop/user-groups.nix.
{ pkgs, ... }:
{
  users.users.xentac = {
    isNormalUser = true;
    description = "Jason Chu";
    shell = pkgs.zsh;
    extraGroups = [
      "wheel" # sudo
    ];
    # No key here on purpose: ssh comes in over tailscale and
    # ~/.ssh/authorized_keys is chezmoi-managed.
  };

  programs.bash.completion.enable = true; # system-wide bash-completion
  security.sudo.wheelNeedsPassword = true;
}
