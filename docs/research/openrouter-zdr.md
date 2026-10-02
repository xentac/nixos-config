# OpenRouter Zero-Data-Retention for Private Claude Code Sessions

Research ticket: evaluate OpenRouter's ZDR story as the main cloud alternative to
"opencode go" for private Claude Code sessions. Researched 2026-10-02 against
OpenRouter primary sources (docs, blog, live `/api/v1/endpoints/zdr` data).

## TL;DR

OpenRouter's ZDR story is substantive, enforceable in-band, and — unusually — it now
speaks the Anthropic Messages protocol natively, so Claude Code wires up with three env
vars and no litellm shim. The real costs are: (1) first-party Anthropic and OpenAI
endpoints are *not* ZDR-classified, so ZDR routing pushes Claude traffic to Bedrock/Vertex
and GPT traffic to Azure; (2) OpenRouter still sees every prompt in transit and retains
request *metadata* (never content, unless you opt in); (3) open-weight model quality
varies per provider (quantization), so provider pinning matters for agentic work.

## 1. How ZDR-only routing works

Source: [ZDR guide](https://openrouter.ai/docs/guides/features/zdr),
[provider routing docs](https://openrouter.ai/docs/features/provider-routing),
[ZDR blog post](https://openrouter.ai/blog/insights/zero-data-retention/).

Three enforcement layers, OR-ed together (any one enables enforcement; a request can
never *weaken* account/guardrail policy):

1. **Account-level**: toggle in [privacy settings](https://openrouter.ai/settings/privacy),
   settable per model group (Anthropic, OpenAI, Google, xAI, "all others").
2. **Guardrail-level**: org guardrails carry `enforce_zdr_anthropic`,
   `enforce_zdr_openai`, etc.
3. **Per-request**: `"provider": {"zdr": true}` in the request body. Docs: the
   per-request flag "can only be used to ensure ZDR is enabled for a specific request,
   not to override or disable account-wide or guardrail enforcement."

When enforced, routing is restricted to endpoints classified ZDR. Classification is
**per endpoint, not per provider** ("a provider's general policy may differ from the
policy attached to a particular model endpoint") and excludes endpoints "retaining data
for abuse or legal review". In-memory prompt caching is allowed under ZDR (not
persistent storage); account-level ZDR disables OpenRouter response caching.
The live list is published at `https://openrouter.ai/api/v1/endpoints/zdr`.

Related but distinct knob: `"data_collection": "deny"` excludes providers that may
*train* on data — OpenRouter notes "no training" is not the same as ZDR.

Caveats:
- ZDR covers post-inference storage by the provider; it does not cover data in transit,
  residency, or third-party tools (under ZDR enforcement the Web Search/Fetch tools
  reject the Firecrawl engine).
- Classification is based on provider policy declarations OpenRouter tracks, not
  cryptographic proof. BYOK keys and private deployments default to non-ZDR unless
  explicitly declared.

### What OpenRouter itself retains

Source: [data collection docs](https://openrouter.ai/docs/guides/privacy/data-collection),
[privacy policy](https://openrouter.ai/privacy).

- "OpenRouter itself has a ZDR policy; your prompts are not retained unless you
  specifically opt in to prompt logging." Prompt/completion logging is **opt-in**
  (observability settings); off by default.
- Always retained: request **metadata** — timestamps, token counts, model, latency,
  cost, app attribution — powering the activity page and rankings. "This metadata does
  not include the content of your prompts or responses."
- Privacy policy: OpenRouter does not train on inputs/outputs; media files are not
  persisted "beyond the duration necessary to route the request, except as required for
  abuse detection, security, billing, or legal compliance."
- Trust model: OpenRouter is still a man-in-the-middle for every prompt in plaintext
  (TLS-terminated). ZDR is a contractual/policy guarantee, not a technical one — same
  class of guarantee as Anthropic's own ZDR agreements.

## 2. Model choice under ZDR (and what it costs you)

Source: live `GET /api/v1/endpoints/zdr` (926 endpoints on 2026-10-02).

The headline constraint: **no first-party Anthropic or OpenAI endpoints are in the ZDR
list.** Claude models route only via **Amazon Bedrock and Google Vertex**; GPT models
only via **Azure**. Gemini (Google) and Grok (xAI first-party) are ZDR-eligible
directly, as are dozens of open-weight hosts.

Frontier-class coding models available through ZDR endpoints today (cheapest listed
endpoint, $/Mtok in/out, all with tool calling):

| Model | ZDR providers | In | Out |
|---|---|---|---|
| anthropic/claude-opus-5.5 | Bedrock, Vertex | 4.00 | 20.00 |
| anthropic/claude-sonnet-5.5 | Bedrock, Vertex | 2.00 | 10.00 |
| anthropic/claude-haiku-4.5 | Bedrock, Vertex | 1.00 | 5.00 |
| openai/gpt-5.3-codex | Azure | 1.75 | 14.00 |
| openai/gpt-5.1-codex-max | Azure | 1.25 | 10.00 |
| google/gemini-3.1-pro-preview | Google | 1.00 | 6.00 |
| x-ai/grok-4.7 | xAI | 2.00 | 6.00 |
| moonshotai/kimi-k3 | 15+ hosts | 3.00 | 15.00 |
| moonshotai/kimi-k2.7-code | Moonshot, Nebius, … | 0.67 | 3.35 |
| z-ai/glm-5.3 | 25 hosts | 0.12 | 1.32 |
| minimax/minimax-m2.5 | Minimax, Novita, … | 0.27 | 0.95 |
| deepseek/deepseek-v4.1-flash | 20+ hosts | 0.04 | 0.42 |
| qwen/qwen3.5-397b-a17b | DeepInfra, Novita, … | 0.45 | 3.00 |

Practical cost of the ZDR restriction: almost nothing in *model* choice — every current
frontier coding family is reachable — but you lose the first-party endpoints (Bedrock/
Vertex/Azure sometimes lag first-party on newest-model availability and features) and
pay the hyperscaler price premium variants (e.g. 5.5/27.5 Bedrock tier rows exist).
Open-weight models keep huge ZDR provider fans, which is where quality variance bites
(section 4).

Platform fees on top of per-token pricing ([pricing](https://openrouter.ai/pricing),
[FAQ](https://openrouter.ai/docs/faq)): 5.5% on Standard-plan credit purchases; BYOK
costs 5% of list price after a free monthly allowance.

## 3. API shape and Claude Code wiring

Source: [Claude Code integration cookbook](https://openrouter.ai/docs/cookbook/coding-agents/claude-code-integration),
[Claude Code blog tutorial](https://openrouter.ai/blog/tutorials/claude-code-openrouter/).

**No litellm/router translation needed.** Besides the OpenAI-compatible
`/api/v1/chat/completions`, OpenRouter exposes an **Anthropic-compatible
`/api/v1/messages` endpoint** (the "Anthropic Skin") implementing the Messages API —
text, images, PDFs, tools, extended thinking — with model mapping handled server-side.
Claude Code speaks its native protocol straight at it:

```bash
export ANTHROPIC_BASE_URL="https://openrouter.ai/api"
export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"   # must be defined before this line
export ANTHROPIC_API_KEY=""                          # explicitly empty, not unset
```

Model tiers map via `ANTHROPIC_DEFAULT_OPUS_MODEL` / `..._SONNET_MODEL` /
`..._HAIKU_MODEL` / `CLAUDE_CODE_SUBAGENT_MODEL` (e.g.
`~anthropic/claude-opus-latest[1m]`; OpenRouter strips the `[1m]` context marker).
Non-Anthropic models can be dropped into those slots, with the documented caveat that
"Claude Code is optimized for Anthropic models and may not work correctly with other
providers."

ZDR fits in two ways: flip the account-level toggle (covers Claude Code without
touching its requests), or — where you control the body — send
`"provider": {"zdr": true}` per request. For Claude Code specifically the account
toggle (or a guardrailed org key) is the clean path since the CLI doesn't emit
OpenRouter provider preferences.

## 4. Tool-calling reliability in agentic use

Source: [Exacto announcement](https://openrouter.ai/blog/announcements/provider-variance-introducing-exacto/),
[tool-calling docs](https://openrouter.ai/docs/guides/features/tool-calling),
community reports ([HN](https://news.ycombinator.com/item?id=45842152), GitHub issues).

- OpenRouter's own telemetry ("billions of LLM tool calls", tracked since Aug 2025 —
  valid JSON, known tool names, schema conformance) shows **measurable tool-calling
  accuracy and propensity variance between providers serving the same open-weight
  model**.
- Root cause reported by the community: hosts serve different quantizations
  (fp4/int4/fp8/bf16) and context ceilings; e.g. GLM 5.3-flash is served by ~33
  endpoints of which several run 4-bit builds. Without pinning, the model behind a
  session can change run to run.
- Mitigations, all compatible with ZDR:
  - `:exacto` model variants route to top tool-calling-accuracy providers (Kimi K2,
    DeepSeek Terminus, GLM 4.6, GPT-OSS-120b, Qwen3-Coder at launch).
  - Provider pinning: `"provider": {"only": ["z-ai"], "allow_fallbacks": false}` (or
    `order` + `require_parameters: true`).
- Claude/GPT/Gemini/Grok via ZDR are hyperscaler or first-party-weight endpoints
  (Bedrock/Vertex/Azure/xAI) — unquantized, so tool-calling reliability matches the
  native APIs; this variance problem is essentially an open-weight-model concern.

## Verdict for the private-Claude-Code use case

Workable and low-friction: account-level ZDR + the Anthropic-compatible endpoint gives
Claude Code on Claude Opus/Sonnet via Bedrock/Vertex at list-ish prices, with
OpenRouter retaining only metadata. Residual exposure vs "opencode go"-style setups:
OpenRouter remains a policy-trusted middleman seeing plaintext prompts, and Claude
traffic rides hyperscaler endpoints rather than Anthropic first-party. If the goal is
cheap private agentic coding instead, GLM-5.3 / Kimi K2.7-code / MiniMax M2.5 under ZDR
with provider pinning (or `:exacto`) are 5–40x cheaper than Claude, at the cost of
Claude Code being tuned for Anthropic models.
