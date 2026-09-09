# Day-to-day commands. `just` (already in your toolbox) runs these.

host := "donatello"

# Build + activate the config (needs sudo)
switch:
    sudo nixos-rebuild switch --flake .#{{host}}

# Build + activate, but only make it the default on NEXT boot
boot:
    sudo nixos-rebuild boot --flake .#{{host}}

# Activate temporarily; reboot reverts to the previous generation
test:
    sudo nixos-rebuild test --flake .#{{host}}

# Evaluate + build without activating (catches typos, no sudo needed)
check:
    nix build .#nixosConfigurations.{{host}}.config.system.build.toplevel --no-link

# Move all inputs (nixpkgs, nixos-hardware) to their latest commits
update:
    nix flake update

# Delete old generations and unreferenced store paths
gc:
    sudo nix-collect-garbage --delete-older-than 30d

# Format all .nix files (runs the flake's formatter output)
fmt:
    nix fmt
