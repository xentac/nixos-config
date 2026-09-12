# sops-nix: secrets live encrypted in secrets/*.yaml (safe to keep in the
# public repo) and are decrypted at activation to /run/secrets/<name> — a
# tmpfs, never the world-readable /nix/store. Decryption uses this machine's
# SSH host key, so it's unattended; editing uses the age key in
# ~/.config/sops/age/keys.txt:
#   sops secrets/donatello.yaml
# Individual secrets are declared next to their consumers (sops.secrets.* in
# backups.nix, monitoring.nix); this module holds the shared plumbing.
{ inputs, pkgs, ... }:
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  # Which file sops.secrets.* names refer to by default. Per-host, so a
  # future second host sets its own (or overrides per-secret with .sopsFile).
  sops.defaultSopsFile = ../../secrets/donatello.yaml;

  # Derive the decryption key from the SSH host key — no separate key to
  # generate, distribute, or back up on the host.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  environment.systemPackages = with pkgs; [
    sops
    ssh-to-age # converts a new host's SSH pubkey for .sops.yaml
  ];
}
