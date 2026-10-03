# Routing Claude Code to non-Anthropic backends

Research note, 2026-10-02. Question: what are the sanctioned/working ways
to point the Claude Code CLI at a non-Anthropic model backend, what does
each cost in ease of use, and can a session be made to send *no* data to
Anthropic?

Sources are primary (Claude Code official docs at code.claude.com,
LiteLLM official docs, project repos via GitHub API). Anecdotal or
unverified claims are flagged inline.

## TL;DR

- `ANTHROPIC_BASE_URL` + an Anthropic-Messages-compatible endpoint is
  **officially documented and supported** — Claude Code has a whole "LLM
  gateway" doc section. The endpoint only strictly needs `POST
  /v1/messages` with SSE streaming and tool use; token counting and
  `/v1/models` are optional.
- **LiteLLM** is the only translation proxy that is company-maintained
  and documents the Claude Code use case first-party. Cost: a ~500 MB
  Python worker with known slow memory growth.
- **claude-code-router** is the healthy community option (37.5k stars,
  active) but has pivoted to a GUI-first desktop app; the lighter
  single-purpose shims are all archived or dormant as of Oct 2026.
- Cleanest per-session switch: a wrapper that sets the env (or `claude
  --settings private.json` / `CLAUDE_CONFIG_DIR=~/.claude-private`).
- **A swapped base URL does NOT stop traffic to Anthropic.** Telemetry,
  error reports, update checks, and release-notes fetches still go out
  unless explicitly disabled; `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`
  is the umbrella switch. Pro/Max subscription auth cannot be used
  through a gateway.

## 1. `ANTHROPIC_BASE_URL` — what the endpoint must implement

Officially documented: [llm-gateway-connect](https://code.claude.com/docs/en/llm-gateway-connect.md),
[llm-gateway-protocol](https://code.claude.com/docs/en/llm-gateway-protocol.md).

Required from the backend:

| Capability | Required | Notes |
|---|---|---|
| `POST /v1/messages` (Anthropic Messages API) | yes | Requests arrive as `/v1/messages?beta=true`; match on path. |
| SSE streaming | yes | Full event sequence; no buffering, dropping, or reordering. |
| Tool use | yes | Claude Code sends full tool definitions and expects tool-use blocks back. |
| `POST /v1/messages/count_tokens` | no | Falls back to character-based estimation if absent. |
| `GET /v1/models` | no | Only queried when `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1`; populates the `/model` picker. Redirects are treated as failure (credential-leak protection). |

Auth: **the env var name determines the header**
([source](https://code.claude.com/docs/en/llm-gateway-connect.md#how-the-credential-variable-maps-to-a-header)):

- `ANTHROPIC_AUTH_TOKEN` → `Authorization: Bearer <value>`
- `ANTHROPIC_API_KEY` → `x-api-key: <value>`
- `apiKeyHelper` script output → both headers (5-min cache,
  `CLAUDE_CODE_API_KEY_HELPER_TTL_MS` to tune)

Wrong variable ⇒ 401 from a gateway that reads the other header.
`ANTHROPIC_CUSTOM_HEADERS` can add extra routing/tenant headers.

Model aliasing (all documented in
[model-config](https://code.claude.com/docs/en/model-config.md)):
`ANTHROPIC_MODEL` overrides the session model; the `opus` / `sonnet` /
`haiku` aliases resolve through `ANTHROPIC_DEFAULT_OPUS_MODEL`,
`ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL` (the
haiku one also pins background-task models). `/model` sends whatever id
is selected, so the id must exist on the gateway; with model discovery
enabled, the picker filters `/v1/models` entries to ids containing
`claude` or `anthropic` (case-insensitive) — a pure `gpt-4o` id will
not appear in the picker and has to be set via env/`/model <name>`.

## 2. LiteLLM as the translation proxy

LiteLLM's proxy exposes an **Anthropic-format `/v1/messages` unified
endpoint** that translates to any configured provider (OpenAI, Gemini,
Bedrock, Ollama, …): [anthropic_unified](https://docs.litellm.ai/docs/anthropic_unified).
(Distinct from the `/anthropic/...` *passthrough*, which is
no-translation and Anthropic-only.) LiteLLM documents Claude Code as a
first-party client:
[client_setup/claude_code](https://docs.litellm.ai/docs/proxy/client_setup/claude_code),
[claude_non_anthropic_models](https://docs.litellm.ai/docs/tutorials/claude_non_anthropic_models).

Minimal config:

```yaml
model_list:
  - model_name: local-qwen            # what Claude Code asks for
    litellm_params:
      model: ollama/qwen2.5           # <provider>/<model-id>
  - model_name: my-gpt
    litellm_params:
      model: openai/gpt-4o
      api_key: os.environ/OPENAI_API_KEY
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

Run: `pip install 'litellm[proxy]'` (or `uv tool install`; Python 3.10+)
then `litellm --config config.yaml` → port 4000; or docker
`ghcr.io/berriai/litellm`. Client side:

```bash
export ANTHROPIC_BASE_URL=http://localhost:4000
export ANTHROPIC_AUTH_TOKEN=$LITELLM_MASTER_KEY
export ANTHROPIC_MODEL=local-qwen
claude
```

Streaming and tool calling are translated on the unified endpoint;
prompt-cache token fields are carried in responses but whether
`cache_control` produces real caching depends on the upstream provider
(not documented per-provider — treat as unavailable off-Anthropic).

**Footprint**: no official minimums in the
[deploy docs](https://docs.litellm.ai/docs/proxy/deploy). LiteLLM's own
performance-roadmap discussion says a single worker consumes ~500 MB
(~200 MB of it Prisma imports)
([#15933](https://github.com/BerriAI/litellm/discussions/15933));
multiple open issues report RAM growth over long runs needing restarts
([#12685](https://github.com/BerriAI/litellm/issues/12685),
[#27954](https://github.com/BerriAI/litellm/issues/27954),
[#15128](https://github.com/BerriAI/litellm/issues/15128) — anecdotal).
Budget 0.5–1 GB per worker plus a MemoryMax + restart policy; it is not
a 50 MB sidecar.

## 3. Community routers (state as of 2026-10-02, via GitHub API)

| Project | Status | Notes |
|---|---|---|
| [musistudio/claude-code-router](https://github.com/musistudio/claude-code-router) | **active** (37.5k stars, v3.1.1 2026-09-16, pushed 2026-09-26) | Grown into a GUI-first "local control plane" (desktop app / `ccr ui`, Node 22+, port 3456) routing Claude Code & others to OpenAI/Gemini/OpenRouter/DeepSeek/custom with rules and fallbacks. Heavier than its old tiny-JSON-daemon form. |
| [1rgs/claude-code-proxy](https://github.com/1rgs/claude-code-proxy) | semi-dormant (last push 2026-06) | FastAPI shim built on LiteLLM anyway — just run LiteLLM. |
| [fuergaosi233/claude-code-proxy](https://github.com/fuergaosi233/claude-code-proxy) | unmaintained since 2026-03 | Similar FastAPI translator. |
| [luohy15/y-router](https://github.com/luohy15/y-router) | **archived** | Cloudflare-Worker → OpenRouter. Dead. |
| claude-bridge ([badlogic/lemmy](https://github.com/badlogic/lemmy)) | dormant (2025-08) | fetch-interception approach. |
| anyrouter.top | n/a | hosted commercial relay, not open source; not evaluated. |

## 4. Per-session switching ("private" sessions)

Settings precedence (highest first): managed → `claude --settings
<file>` → `.claude/settings.local.json` → `.claude/settings.json` →
`~/.claude/settings.json`
([settings](https://code.claude.com/docs/en/settings.md)). Env can live
in the `env` block of any settings file, and settings-file env
overrides shell env
([env-vars precedence](https://code.claude.com/docs/en/env-vars.md#precedence-rules)).

Three clean patterns, default setup untouched:

1. **Shell wrapper / alias** exporting `ANTHROPIC_BASE_URL`,
   `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL`, plus the kill switches in
   §6. Simplest; on NixOS a `writeShellScriptBin "claude-private"` fits.
2. **`claude --settings ~/.claude/private-settings.json`** with an
   `env` block carrying the same variables — session-scoped, highest
   non-managed precedence.
3. **`CLAUDE_CONFIG_DIR=~/.claude-private claude`** — a fully separate
   profile (own settings, history, credentials), documented for
   multi-account use
   ([authentication](https://code.claude.com/docs/en/authentication.md#log-in-with-multiple-accounts)).
   Strongest isolation: the private profile never even holds the
   Anthropic OAuth credential.

Caution for "private": patterns 1–2 share `~/.claude` history/state
with the normal profile; only pattern 3 separates session transcripts.

## 5. What degrades on a non-Anthropic backend

From [llm-gateway-protocol](https://code.claude.com/docs/en/llm-gateway-protocol.md)
and [llm-gateway](https://code.claude.com/docs/en/llm-gateway.md):

- **Subscription auth**: Pro/Max OAuth login **cannot** be used through
  a gateway — once a gateway credential variable (or `apiKeyHelper`) is
  set, it replaces the subscription login. Expect to pay the upstream
  provider per-token.
- **Prompt caching**: works only if the chain forwards `cache_control`
  *and* the upstream model actually implements Anthropic-style caching;
  otherwise every turn bills as uncached input.
- **Thinking**: adaptive reasoning (4.6+) is sent as a `thinking` body
  field even for unrecognized model ids — incompatible upstreams return
  400 naming `thinking`/`adaptive`; extended-thinking beta headers are
  silently dropped if stripped. `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`
  avoids context-management 400s on non-Anthropic upstreams.
- **Tool calling**: the wire format is translated by LiteLLM, but
  reliability is bounded by the upstream model; Claude Code's prompts
  and tool schemas are tuned for Claude (observation, not a doc claim).
- **Features that shut off**: Remote Control (any non-Anthropic base
  URL, v2.1.196+), voice dictation (while a gateway credential is
  active), WebFetch domain-safety checks still want api.anthropic.com.
- **Context window**: Claude Code applies its own default window to
  unrecognized model names ([LiteLLM tutorial](https://docs.litellm.ai/docs/tutorials/claude_non_anthropic_models)).

## 6. Residual traffic to Anthropic, and silencing it

Key doc statement: with `ANTHROPIC_BASE_URL` set, **only inference**
goes to the gateway; "telemetry events, version checks, release notes,
and similar requests" still reach Anthropic/third parties — without the
gateway credential attached
([turn-off-traffic](https://code.claude.com/docs/en/llm-gateway-connect.md#turn-off-traffic-outside-the-gateway-path)).

| Switch | Silences |
|---|---|
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` | umbrella: auto-updates, telemetry, error reporting, release-notes fetch, etc. |
| `DISABLE_TELEMETRY=1` | Statsig feature flags + Datadog usage metrics (not error reports) |
| `DISABLE_ERROR_REPORTING=1` | Sentry/Datadog error intake |
| `DISABLE_AUTOUPDATER=1` | update checks to downloads.claude.ai (docs also reference `CLAUDE_CODE_DISABLE_AUTO_UPDATE`; equivalence not fully documented) |
| `DISABLE_BUG_COMMAND=1`, `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1` | `/bug`, survey prompts |

Domains Claude Code otherwise contacts
([network-config](https://code.claude.com/docs/en/network-config.md#network-access-requirements)):
`api.anthropic.com` (API + WebFetch safety checks + feature flags +
telemetry), `http-intake.logs.us5.datadoghq.com`,
`browser-intake-us5-datadoghq.com`, `downloads.claude.ai`,
`raw.githubusercontent.com` (release notes), `github.com` (plugins).

**For a genuinely no-data-to-Anthropic session**: set the umbrella
variable *plus* the individual DISABLE_* vars (belt and braces), use a
`CLAUDE_CONFIG_DIR` profile with no Anthropic credential stored, avoid
WebFetch (its domain-safety check calls api.anthropic.com), and ideally
verify with an egress firewall — the docs enumerate switches but a
network-level block is the only guarantee.

## Recommendation for this repo

If/when this is wanted: LiteLLM on alba-nix or localhost (NixOS has a
`services.litellm`-shaped option via the litellm package, or a simple
systemd unit with `MemoryMax=1G` and periodic restart), one `model_name`
per private model, and a `claude-private` wrapper script setting
`CLAUDE_CONFIG_DIR`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`,
`ANTHROPIC_MODEL`, and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` +
`DISABLE_TELEMETRY=1` + `DISABLE_ERROR_REPORTING=1` +
`DISABLE_AUTOUPDATER=1`.
