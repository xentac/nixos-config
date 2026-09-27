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

# UI-made service config edits on the target since its last rebuild/restart
drift-config target="alba-nix" *svcs="":
    ssh root@{{target}} config-drift {{svcs}}

# Move all inputs (nixpkgs, nixos-hardware) to their latest commits
update:
    nix flake update

# Delete old generations and unreferenced store paths
gc:
    sudo nix-collect-garbage --delete-older-than 30d

# Format all .nix files (runs the flake's formatter output)
fmt:
    nix fmt

# After pasting a Grafana export over a dashboard file, normalize it
# in place. Classic model: strip volatile id/version. v2 export
# (Grafana 13 can produce nothing else, even under "Classic" —
# grafana/grafana#126641): keep apiVersion/kind/metadata.name/spec,
# drop the server-side metadata. Both: check the uid didn't change
# vs git. docs/grafana-dashboards.md:
# Normalize a pasted Grafana dashboard JSON file in place
dashboard file:
    #!/usr/bin/env bash
    set -euo pipefail
    file={{quote(file)}}
    if ! jq -e . "$file" >/dev/null 2>&1; then
        echo "error: $file is not valid JSON (starts: $(head -c 120 "$file"))" >&2; exit 1
    fi
    # uid of the previous revision: classic keeps it at .uid, v2 at .metadata.name
    git_uid=$(git show "HEAD:$file" 2>/dev/null | jq -r '.metadata.name // .uid // empty' || true)
    if jq -e '.panels? | type == "array"' "$file" >/dev/null; then
        uid=$(jq -r '.uid // empty' "$file")
        if [ -z "$uid" ]; then
            echo "error: classic model has no uid; set a stable kebab-case uid first" >&2; exit 1
        fi
        jq 'del(.id, .version)' "$file" > "$file.tmp"
    elif jq -e '(.spec // .) | (.elements != null and .layout != null)' "$file" >/dev/null; then
        # full resource (apiVersion/kind/metadata/spec) or bare spec both accepted
        uid=$(jq -r '.metadata.name // empty' "$file")
        uid=${uid:-$git_uid}
        if [ -z "$uid" ]; then
            echo "error: can't determine uid: no .metadata.name in the paste and no previous revision in git." >&2
            echo "For a new dashboard, wrap the spec: {\"metadata\": {\"name\": \"<kebab-case-uid>\"}, \"spec\": ...}" >&2; exit 1
        fi
        jq --arg uid "$uid" '{apiVersion: (.apiVersion // "dashboard.grafana.app/v2"), kind: "Dashboard", metadata: {name: $uid}, spec: (.spec // .)}' "$file" > "$file.tmp"
    else
        echo "error: neither a classic JSON model (.panels) nor a v2 dashboard (.elements + .layout)" >&2; exit 1
    fi
    if [ -n "$git_uid" ] && [ "$uid" != "$git_uid" ]; then
        rm -f "$file.tmp"
        echo "error: uid changed ($git_uid -> $uid); keep the uid stable or the provisioner will duplicate the dashboard" >&2; exit 1
    fi
    mv "$file.tmp" "$file"
    echo "normalized $file (uid $uid)"
