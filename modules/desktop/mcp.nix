# MCP servers for Claude Code. One that needs a credential is a wrapper
# that reads it from sops at exec time, so the MCP registration (`claude
# mcp add ... -- <wrapper>`, kept in ~/.claude.json) never holds a secret.
{ config, pkgs, ... }:
let
  # Grafana's official MCP server against alba-nix's Grafana (tailnet).
  # The token belongs to alba-grafana's `claude-mcp` service account (Viewer
  # role); --disable-write keeps it read-only even if the role grows.
  # Metrics work through the VictoriaMetrics (Prometheus-type) datasource;
  # its log tools are Loki-only, so VictoriaLogs isn't reachable from here.
  mcp-grafana-alba = pkgs.writeShellApplication {
    name = "mcp-grafana-alba";
    runtimeInputs = [ pkgs.mcp-grafana ];
    text = ''
      GRAFANA_SERVICE_ACCOUNT_TOKEN=$(<${config.sops.secrets."alba-grafana/mcp_token".path})
      export GRAFANA_SERVICE_ACCOUNT_TOKEN
      export GRAFANA_URL=https://alba-grafana.stalk-darter.ts.net
      exec mcp-grafana --disable-write "$@"
    '';
  };
in
{
  # The bare service-account token (glsa_...). Owned by the user who runs
  # Claude Code.
  sops.secrets."alba-grafana/mcp_token".owner = "xentac";

  environment.systemPackages = [
    mcp-grafana-alba
    # nixpkgs / NixOS / home-manager package and option lookup. Public
    # data, no credential, so no wrapper: registered as
    # `claude mcp add -s user nixos -- mcp-nixos`.
    pkgs.mcp-nixos
  ];
}
