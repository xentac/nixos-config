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

    # Encrypted secrets in git (secrets/*.yaml), decrypted at activation with
    # each host's SSH key. See modules/common/secrets.nix and .sops.yaml.
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # Declarative disk partitioning, used by servers installed with
    # nixos-anywhere (hosts/alba-nix/disko.nix). The laptop predates disko
    # and keeps its hand-partitioned hardware-configuration.nix.
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # Remote deployment (`just deploy alba-nix`) with magic rollback: if the
    # new generation breaks SSH, the node reverts on its own — important for
    # servers we can't easily walk over to.
    deploy-rs.url = "github:serokell/deploy-rs";
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
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

      # The boat-services VM on Alba's Proxmox host. Installed remotely with
      #   nixos-anywhere --flake .#alba-nix root@<installer-ip>
      # and updated with `just deploy alba-nix` (deploy-rs, see below).
      nixosConfigurations.alba-nix = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [ ./hosts/alba-nix ];
      };

      # Remote hosts deployed with deploy-rs. Donatello is absent on purpose:
      # the laptop rebuilds itself locally (`just switch`). One node per
      # server; a future fleet is more entries here.
      deploy.nodes.alba-nix = {
        hostname = "alba-nix";
        profiles.system = {
          user = "root";
          sshUser = "root";
          path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.alba-nix;
        };
      };

      # `nix flake check` verifies every deploy node's config matches its
      # nixosConfiguration (schema + build), alongside the usual eval checks.
      checks.x86_64-linux = inputs.deploy-rs.lib.x86_64-linux.deployChecks self.deploy;

      # `nix fmt` (and `just fmt`) formats the whole tree with nixfmt.
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;
    };
}
