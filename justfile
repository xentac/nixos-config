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

# For a remote target the running generation's store path comes over
# SSH; its closure is normally already in the local store because
# deploys build here. (just shows the last comment line in --list:)
# Diff the target's running generation against a fresh build of the config
diff target=host:
    #!/usr/bin/env bash
    set -euo pipefail
    new=$(nix build .#nixosConfigurations.{{target}}.config.system.build.toplevel --no-link --print-out-paths)
    if [ "{{target}}" = "$(hostname)" ]; then
        current=/run/current-system
    else
        current=$(ssh root@{{target}} readlink -f /run/current-system)
    fi
    nix run nixpkgs#nvd -- diff "$current" "$new"

# Build locally, push to the remote over SSH, auto-rollback if SSH breaks
deploy target="alba-nix":
    nix run nixpkgs#deploy-rs -- .#{{target}}

# Like deploy, but the remote only switches to it on its NEXT boot
deploy-boot target="alba-nix":
    nix run nixpkgs#deploy-rs -- .#{{target}} --boot

# Move all inputs (nixpkgs, nixos-hardware) to their latest commits
update:
    nix flake update

# Delete old generations and unreferenced store paths
gc:
    sudo nix-collect-garbage --delete-older-than 30d

# Format all .nix files (runs the flake's formatter output)
fmt:
    nix fmt
