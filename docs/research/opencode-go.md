# OpenCode Go as a backend for routing Claude Code CLI to zero-data-retention models

Research date: 2026-10-02. Question: can "opencode go" (https://opencode.ai/go) serve as a
backend for pointing Claude Code CLI at zero-data-retention (ZDR) models — what is it, which
models are ZDR, what does it cost, is there an externally consumable API, and can auth live in
a headless gateway?

**Short answer: viable.** Go is a flat-rate subscription gateway ($10 or $40/mo) to ~29
open-weight coding models, most with 0-day retention, exposed over an **Anthropic-compatible
HTTP endpoint** (`https://opencode.ai/zen/go/v1/messages`) authenticated by a plain API key —
and OpenCode's docs explicitly list **Claude Code as a validated client**. No bridge (litellm,
local proxy) is required, though litellm works if multiplexing is wanted anyway.

## What it is

OpenCode Go is a hosted subscription from the opencode project (Anomaly; repo
`github.com/anomalyco/opencode`, formerly `sst/opencode`). Marketing: "Go brings agentic
coding to programmers around the world. Offering generous limits and reliable access to the
most capable open-source models." ([opencode.ai/go](https://opencode.ai/go))

It is distinct from **OpenCode Zen** ([docs](https://opencode.ai/docs/zen/)), the pay-as-you-go
gateway that also carries frontier closed models (GPT, Claude, Gemini). Go is the flat-rate
tier limited to open-weight models; it shares Zen's gateway infrastructure (Go's endpoints live
under `/zen/go/`).

## Models and zero-data-retention terms

~29 models as of 2026-10: Kimi K3 / K2.7 Code / K2.6, DeepSeek V4.x, GLM-5.x, Qwen3.7/3.8,
MiniMax M3/M2.7, MiMo, LongCat, Grok 4.6/4.7, GPT 6/5.6 Luna, Muse Spark (Meta), Hy, plus
rotating free models. ([opencode.ai/docs/go/](https://opencode.ai/docs/go/))

Retention, per the per-model table in the Go docs
([opencode.ai/docs/go/](https://opencode.ai/docs/go/)) and the console models page
([opencode.ai/v2/docs/console/models/](https://opencode.ai/v2/docs/console/models/)):

- **0-day retention, not used for training** — GLM, Kimi, Qwen, MiniMax, DeepSeek, MiMo,
  LongCat, Hy, Space Bunny Free. Blanket statement: "All our models are hosted in the US. Our
  providers follow a zero-retention policy and do not use your data for model training,"
  with listed exceptions.
- **Exceptions (NOT ZDR):** Grok 4.6/4.7 and GPT 6 Luna / 5.6 Luna — 30-day retention for
  abuse monitoring; Muse Spark "Contributor" models — prompts/completions may train future
  Meta models (that's the discount's price); some free/beta models may use data for
  improvement during the free period; Nemotron free endpoints log for security.
- DeepSeek's ZDR agreement is noted as valid through 2026-10-31 (presumably renewable) —
  worth re-checking after that date.

Where the terms live: the model-level ZDR statements are in the two docs pages above (no
separate contract document). OpenCode's own privacy policy
([opencode.ai/legal/privacy-policy](https://opencode.ai/legal/privacy-policy), effective
2026-03-06) lists prompt content as "Passing through to upstream provider to provide
services" / "Not stored" — i.e. the gateway itself claims pass-through, and retention is a
property of each upstream provider. Terms of service:
[opencode.ai/legal/terms-of-service](https://opencode.ai/legal/terms-of-service).

**Practical ZDR posture:** stick to the open-weight set (Kimi/GLM/Qwen/DeepSeek/MiniMax) and
avoid Grok, the GPT Luna models, Muse Spark Contributor, and free-tier models. The console's
team workspace supports disabling specific models, which can enforce this.

## Pricing

- **Go: $10/month. Go Plus: $40/month** ("higher usage caps"). One subscriber per workspace.
- Flat-rate with dollar-denominated usage allowances per model: Go $15–$60/model/month,
  Go Plus $60–$240/model/month, metered in rolling windows — 5-hour window = 20% of monthly
  allowance, weekly = 50%, monthly = 100%. On hitting a limit you can keep using free models.
- Credit top-up exists (FAQ mentions it) for overage.

Source: [opencode.ai/go](https://opencode.ai/go), [opencode.ai/docs/go/](https://opencode.ai/docs/go/).

## API shape — externally consumable, Anthropic-compatible

Go is **not** CLI-locked. Documented endpoints ([opencode.ai/docs/go/](https://opencode.ai/docs/go/)):

| Endpoint | Protocol |
|---|---|
| `https://opencode.ai/zen/go/v1/messages` | Anthropic Messages API |
| `https://opencode.ai/zen/go/v1/chat/completions` | OpenAI chat completions |
| `https://opencode.ai/zen/go/v1/responses` | OpenAI Responses API |
| `https://opencode.ai/zen/go/v1/models` | model list |

Verified by probe on 2026-10-02:

- `GET /zen/go/v1/models` returns the model list unauthenticated (bare ids: `kimi-k3`,
  `glm-5.3`, `minimax-m3`, …). The `opencode-go/<id>` form is opencode-CLI config syntax;
  the raw API takes bare ids.
- `POST /zen/go/v1/messages` returns Anthropic-style error envelopes
  (`{"type":"error","error":{...}}`); with no key: `AuthError: Missing API key.`; with
  `x-api-key: invalid`: `AuthError: Invalid API key.`
- `Authorization: Bearer <key>` was **not** recognized on `/messages` in the probe (still
  "Missing API key") — so use the `x-api-key` header path.

**Claude Code integration:** the Go docs have a "Validated Clients" list that includes
**Claude Code** ("Go recognizes its native session header. No custom-header wrapper is
needed" — clients must send a stable session id, which Claude Code does natively). So the
direct wiring is:

```bash
ANTHROPIC_BASE_URL=https://opencode.ai/zen/go
ANTHROPIC_API_KEY=<go api key>        # x-api-key header; do NOT use ANTHROPIC_AUTH_TOKEN (Bearer not accepted)
ANTHROPIC_MODEL=kimi-k3               # or glm-5.3, minimax-m3, ...
```

(Also listed as validated: Codex, Kilo Code CLI, etc. "Known problematic clients" exist too —
those lack session-header support.)

**Bridge option:** litellm can front it as a generic `anthropic` provider with `api_base`
pointing at `/zen/go` (or `openai`-style via `/chat/completions`) if you want one gateway URL
across providers — useful but optional; the candidate does not die here.

## Auth / headless suitability

Issuance is interactive once: sign in at the [OpenCode Console](https://opencode.ai/auth),
subscribe, copy the API key. After that the key is a **static bearer-style secret with no
interactive/OAuth refresh**, suitable for sops-nix and a headless gateway (litellm on a
server) or direct env-var injection into Claude Code. The opencode CLI itself just pastes the
same key via `/connect`. Docs don't mention key rotation or multiple keys per account; team
workspaces add per-user roles, spending limits, and model allow/deny.

## Verdict for the ticket

Candidate **survives**. Direct Claude Code → Go wiring is first-party-validated,
Anthropic-protocol, static-key, headless-friendly. ZDR holds for the open-weight majority of
the catalog but is per-model, so pin the model allowlist. Residual risks: ZDR claims are docs
statements (not a signed DPA), the DeepSeek ZDR term has a stated expiry (2026-10-31), and
Bearer-auth absence means tools that only speak `Authorization:` headers need litellm in front.

## Sources

- https://opencode.ai/go — product page, pricing, FAQ headings
- https://opencode.ai/docs/go/ — Go docs: models, limits, retention table, validated clients, endpoints
- https://opencode.ai/docs/zen/ — Zen docs (the sibling pay-as-you-go gateway)
- https://opencode.ai/v2/docs/console/models/ — console models page, blanket ZDR statement + exceptions
- https://opencode.ai/legal/privacy-policy — "Not stored" pass-through for prompt content
- https://opencode.ai/legal/terms-of-service
- https://github.com/anomalyco/opencode — source repo (sst/opencode redirects here)
- Live endpoint probes of `https://opencode.ai/zen/go/v1/*`, 2026-10-02
