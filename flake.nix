# flake.nix — the entry point of the whole configuration.
#
# A "flake" is just a Nix file with two things: `inputs` (other repos this
# config depends on, pinned by flake.lock) and `outputs` (what this repo
# produces — here, one NixOS system). `nixos-rebuild switch --flake .#donatello`
# evaluates outputs.nixosConfigurations.donatello and activates it.
{
  description = "Jason's NixOS configuration";

  inputs = {
    # The package set + NixOS modules. Pinned to the 26.05 stable branch;
    # `nix flake update` moves the pin forward within that branch.
    # Swap to "github:NixOS/nixpkgs/nixos-unstable" for a rolling setup.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Community hardware quirks (Framework laptop kernel modules, power
    # tweaks, fingerprint reader, etc). Consumed in hosts/donatello/default.nix.
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    # nixos-hardware declares its own nixpkgs (for its CI); point it at ours
    # so flake.lock doesn't carry a second, stale nixpkgs pin.
    nixos-hardware.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-hardware,
      ...
    }@inputs:
    {
      # One machine == one entry here. Add a second laptop/server later by
      # adding another attribute pointing at another hosts/<name> directory.
      nixosConfigurations.donatello = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        # `specialArgs` makes `inputs` available as an argument to every module,
        # so modules can reference e.g. inputs.nixos-hardware.
        specialArgs = { inherit inputs; };
        modules = [ ./hosts/donatello ];
      };

      # `nix fmt` (and `just fmt`) formats the whole tree with nixfmt.
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;
    };
}
