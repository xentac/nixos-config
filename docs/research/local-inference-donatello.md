# Research: local LLM inference on donatello as a private tier

Date: 2026-10-02. Question: is local inference on donatello (Framework
Laptop 13, AMD Ryzen AI 300 series, Radeon 890M iGPU, 64 GB shared
LPDDR5x, NixOS) good enough to be a real tier for private sessions, and
at what cost?

## TL;DR

Yes, as a **narrow tier**: Qwen3-Coder-30B-A3B or GLM-4.7-Flash
(30B-A3B MoE, Q4–Q6) over llama.cpp **Vulkan** (not ROCm) at ~20+ tok/s,
served on demand via `services.llama-swap` (packaged + module in our
pin) with a TTL so idle cost is ~zero, and plugged straight into Claude
Code via llama.cpp's **native Anthropic `/v1/messages` endpoint** — no
proxy. That's credible for private chat, sensitive-content work, and
supervised small-scope agentic coding at roughly Claude-3.5-Sonnet-era
competence. It is not a general replacement tier: dense ≥30B models and
the ~110B MoE class are out (the Framework 13's DDR5-5600 gives only
~90 GB/s, 2.5–3× less than Strix Halo), long/parallel agent sessions
degrade, and a loaded model pins ~20-25 GB of GTT on the daily driver.
The NPU is irrelevant for now.

## What this repo already has (verified against the flake pin)

The flake pins `nixos-26.05` at rev `5e2305d5` (`flake.lock`). Checked
directly against that rev of nixpkgs:

- **ROCm 7.2.3** (`rocmPackages`, `pkgs/development/rocm-modules/rocm-core`),
  and `rocmPackages.clr` **compiles kernels for `gfx1150` ("Strix Point")
  explicitly** — it is in the default `gpuTargets` list alongside
  `gfx1151` (Strix Halo) and `gfx1103` (780M).
  [clr/default.nix](https://github.com/NixOS/nixpkgs/blob/5e2305d577ca00acbba631b05cb1094d172b29f3/pkgs/development/rocm-modules/clr/default.nix)
- **ollama 0.32.3** with `acceleration` one of `null / false / "rocm" /
  "cuda" / "vulkan"`, plus pre-built `ollama-rocm` / `ollama-vulkan`
  variants.
  [ollama/package.nix](https://github.com/NixOS/nixpkgs/blob/5e2305d577ca00acbba631b05cb1094d172b29f3/pkgs/by-name/ol/ollama/package.nix)
- **`services.ollama`** module options include `rocmOverrideGfx`,
  `environmentVariables`, `loadModels`, `syncModels`, `host`/`port`,
  `openFirewall`. There is **no `keepAlive` option** — set
  `OLLAMA_KEEP_ALIVE` via `environmentVariables`.
  [ollama.nix](https://github.com/NixOS/nixpkgs/blob/5e2305d577ca00acbba631b05cb1094d172b29f3/nixos/modules/services/misc/ollama.nix)
- **llama.cpp b9190** as `llama-cpp`, with prebuilt `llama-cpp-vulkan`
  and `llama-cpp-rocm` top-level attrs.
- **llama-swap v224** is packaged *and* has a NixOS module,
  `services.llama-swap` (`enable`, `port`, `settings`, TLS,
  `openFirewall`).
  [llama-swap.nix](https://github.com/NixOS/nixpkgs/blob/5e2305d577ca00acbba631b05cb1094d172b29f3/nixos/modules/services/networking/llama-swap.nix)
- donatello already imports
  `nixos-hardware.nixosModules.framework-amd-ai-300-series`
  (`hosts/donatello/default.nix`); that module handles fwupd, audio
  quirks, and kernel floor — nothing GPU-compute related, so inference
  config is all additive. `services.ollama.enable = false` sits as a
  stub in `modules/desktop/apps.nix`.
- The machine has 64 GB RAM and a 64 GB encrypted swap device
  (hibernate-sized), which matters for the memory-pressure story below.

## 1. Acceleration under NixOS

**Vulkan (RADV) is the right backend for this iGPU, not ROCm.** The
decisive issue: on gfx1150, ROCm's `hipMalloc` allocates only from the
BIOS-carved VRAM (UMA buffer) and never from GTT, so large models
fragment and throughput collapses; RADV Vulkan allocates from VRAM+GTT
(~half of RAM by default, raisable). Measured on exactly this chip
(Ryzen AI 9 HX 370 / 890M): pp512 370 t/s Vulkan vs 150 t/s ROCm, tg128
23 vs 18 t/s
([lemonade-sdk/llamacpp-rocm #57](https://github.com/lemonade-sdk/llamacpp-rocm/issues/57),
corroborated by [this 890M gist](https://gist.github.com/Randomblock1/bf9b15926d7f6e96defb839f63c175a3)
and the Framework-13 benchmark in §2). Even AMD's own GAIA uses Vulkan,
not ROCm, on iGPUs ([Lemonade FAQ](https://lemonade-server.ai/docs/guide/faq/)).

**ROCm status anyway:** gfx1150 became *officially* supported only in
ROCm 7.2.1 via the Radeon/Ryzen track (Ryzen AI 9 HX 370 listed,
[AMD compat matrix](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/compatibility/compatibilityryz/native_linux/native_linux_compatibility.html));
before that AMD said the 890M was unsupported
([Framework forum](https://community.frame.work/t/amd-rocm-does-not-support-the-amd-ryzen-ai-300-series-gpus/68767)).
Our pinned nixpkgs ships ROCm 7.2.3 with gfx1150 kernels compiled in
(§0), so **no `HSA_OVERRIDE_GFX_VERSION` is needed** on this stack (the
old trick was `11.0.0`/`11.0.2` on pre-7.2 ROCm,
[llm-tracker](https://llm-tracker.info/howto/AMD-GPUs)).

**Concrete NixOS config:**

- `services.ollama.enable = true; services.ollama.package =
  pkgs.ollama-vulkan;` (the old `acceleration` option is gone on
  26.05-class modules — package selection instead; `rocmOverrideGfx`
  exists but isn't needed).
- Or `services.llama-swap` + `(pkgs.llama-cpp.override { vulkanSupport
  = true; })` — note plain `llama-cpp` builds **without** Vulkan by
  default; `llama-cpp-vulkan` is the prebuilt attr.
- `hardware.graphics.enable = true` (already on for a desktop host)
  gives RADV + the Vulkan ICD; ROCm would additionally want
  `rocmPackages.clr.icd` in `hardware.graphics.extraPackages`
  ([NixOS wiki Framework 13](https://wiki.nixos.org/wiki/Hardware/Framework/Laptop_13)).
- For >RAM/2 GPU allocations, GTT/TTM limits are tunable via
  `boot.kernelParams` (`ttm.pages_limit=`, `ttm.page_pool_size=`;
  `amdgpu.gttsize` is deprecated on new kernels where GTT already
  defaults to ~half of RAM —
  [Framework Strix Halo guide](https://community.frame.work/t/amd-strix-halo-llama-cpp-installation-guide-for-fedora-42/75856)).
  With 64 GB RAM the ~32 GB default GTT covers every model that makes
  sense here (§2), so this is likely unnecessary. The nixos-hardware
  module donatello imports sets none of this (verified; it's
  fwupd/audio/kernel-floor only).

**XDNA NPU: real but not practical on NixOS yet.** The `amdxdna` kernel
driver is mainline since Linux 6.14 (donatello runs
`linuxPackages_latest`, so it's present —
[Phoronix](https://www.phoronix.com/review/linux-614-features)). AMD's
Ryzen AI NPU/hybrid LLM stack is still Windows-only; on Linux the only
LLM path is FastFlowLM via Lemonade Server 10.0 (XDNA2-only, which this
machine's NPU is —
[Phoronix](https://www.phoronix.com/news/AMD-Ryzen-AI-NPUs-Linux-LLMs)),
and none of that userspace (XRT/xdna, FastFlowLM, Lemonade) is in
nixpkgs. The NPU also wouldn't beat the iGPU for LLM decode — both are
bound by the same memory bus. Ignore it for this purpose; revisit if
Lemonade lands in nixpkgs.

## 2. Model ceiling with 64 GB shared RAM

**Premise correction: the Framework 13 is the slow-memory Strix Point.**
It uses socketed DDR5-5600 SO-DIMMs on a 128-bit bus — **89.6 GB/s
theoretical, ~63–67 GB/s measured effective** — not the LPDDR5x-7500
(120 GB/s) of soldered-RAM Strix Point laptops
([first-hand Framework 13 HX 370 benchmark](https://msf.github.io/blogpost/local-llm-performance-framework13.html),
[HX 370 specs](https://www.waredb.com/processor/amd-ryzen-ai-9-hx-370)).
Token generation is bandwidth-bound, so this number drives everything
below. For contrast, Strix Halo (Ryzen AI Max+ 395) has 256 GB/s
theoretical / ~212 GB/s measured — 2.5–3× this machine; don't confuse
their benchmarks
([llm-tracker Strix Halo](https://llm-tracker.info/AMD-Strix-Halo-(Ryzen-AI-Max+-395)-GPU-Performance)).

**What fits in ~48–56 GB usable:**

| Model | Quant / size | Fits? |
|---|---|---|
| Qwen3-Coder-30B-A3B / Qwen3-30B-A3B | Q4_K_M ~18.6 GB, Q8_0 ~32.5 GB | Yes, easily |
| gpt-oss-20b | MXFP4 ~11.3 GB | Yes, easily |
| Qwen3-32B dense | Q4_K_M ~19.8 GB | Yes |
| Devstral Small 24B | Q4_K_M ~14.3 GB | Yes |
| Llama-3.3-70B | Q4_K_M ~42.5 GB | Loads, little KV headroom |
| GLM-4.5-Air (106B-A12B) | Q4_K_M 73 GB; UD-Q2_K_XL ~46 GB ([unsloth GGUF](https://huggingface.co/unsloth/GLM-4.5-Air-GGUF)) | Only at ~Q2/IQ3, tight |
| gpt-oss-120b | MXFP4 59–63 GB ([ggml-org GGUF](https://huggingface.co/ggml-org/gpt-oss-120b-GGUF)) | **No** (would need the 96 GB SO-DIMM upgrade Framework supports) |

Add ~1–4 GB KV cache for 8–32K context on the 30B-class models.

**Measured speeds on this exact hardware** (Framework 13 HX 370, 64 GB
DDR5-5600, Linux, Vulkan/RADV, performance profile —
[msf.github.io](https://msf.github.io/blogpost/local-llm-performance-framework13.html)):

| Model | pp512 | tg128 |
|---|---|---|
| gpt-oss-20b MXFP4 (MoE, ~3.6B active) | 390 t/s | **23.4 t/s** |
| Qwen3-8B Q4_K_M | 322 t/s | 13.4 t/s |
| Qwen3-8B + 0.6B speculative decoding | — | ~22.9 t/s (~17.6 coding) |

Same source: **Vulkan/RADV beats ROCm ~2× on token generation** on
gfx1150 (ROCm wins prompt processing). Corroborating: deepseek-r1 14B Q4
at ~7–8 t/s on the Framework forum
([FW13 AI 370 thread](https://community.frame.work/t/fw13-ai-370-performance/70063)).

**Estimates (no direct measurement found, bandwidth math):**
Qwen3-Coder-30B-A3B Q4 ≈ **20–28 t/s** tg (consistent with the measured
gpt-oss-20b, similar active size); 32B dense Q4 ≈ 3–3.5 t/s; 70B Q4 ≈
1.5 t/s; GLM-4.5-Air at Q2/IQ3 maybe 8–11 t/s with real quant-quality
loss and no KV headroom.

**Conclusion:** the usable ceiling is **small-active-parameter MoE**:
Qwen3-Coder-30B-A3B and gpt-oss-20b run at genuinely interactive speed;
dense ≥14B is borderline-to-painful; the ~110B MoE class does not
usefully fit at 64 GB.

## 3. Memory profile and daily-driver ergonomics

**ollama.** A model stays loaded 5 minutes after the last request by
default; `keep_alive` accepts durations, `-1` (forever), `0` (unload
immediately), settable globally via `OLLAMA_KEEP_ALIVE` or per-request
([ollama FAQ](https://docs.ollama.com/faq)). `OLLAMA_MAX_LOADED_MODELS`
defaults to 3×GPUs. The daemon itself is a small Go server; the model
lives in a spawned "runner" subprocess, so unload = process kill and the
GTT allocations go back to the kernel. Caveats: ollama historically had
zombie-runner bugs holding VRAM
([#10114](https://github.com/ollama/ollama/issues/10114)), and on AMD
iGPUs it treats shared GTT "free memory" as if it were dedicated VRAM,
which can over-commit RAM
([#14953](https://github.com/ollama/ollama/issues/14953),
[machinezoo writeup](https://blog.machinezoo.com/Running_Ollama_on_AMD_iGPU)).
Keep `keep_alive` short on a daily driver. Note: iGPU allocations come
from GTT, not the BIOS VRAM carve-out — leave the UMA buffer small.

**llama.cpp.** `llama-server` was one-process-one-model, but 2026 added
a router mode (`--models-dir`, `--models-max`, `--models-autoload`)
([server README](https://github.com/ggml-org/llama.cpp/tree/master/tools/server)).
Weights are mmap'd read-only by default: file-backed page cache, lazily
loaded and **evictable under memory pressure without touching swap**
([justine.lol/mmap](https://justine.lol/mmap/),
[discussion #638](https://github.com/ggml-org/llama.cpp/discussions/638)).
So an idle llama-server with a 25 GB model "loaded" mostly costs
reclaimable page cache; RES in htop overstates it. KV cache and compute
buffers are always anonymous (or GTT-pinned on the iGPU) and stay
resident for the process lifetime. `--no-mmap`/`--mlock` were replaced
in 2026 by `--load-mode auto|none|mmap|mlock|mmap+mlock|dio`
([#26110](https://github.com/ggml-org/llama.cpp/issues/26110)); avoid
`mlock` on this machine.

**llama-swap** ([README](https://github.com/mostlygeek/llama-swap)) is
the clean daily-driver answer: a tiny proxy that cold-starts the right
llama-server per requested model, swaps between them, and auto-unloads
via per-model `ttl` seconds; it proxies OpenAI **and Anthropic
`/v1/messages`** endpoints. Idle state = a few-MB Go proxy, zero GTT.
Packaged in the pinned nixpkgs with a `services.llama-swap` module (see
above).

**Pattern for donatello:** `services.llama-swap` with `ttl` 300–900 s
(or ollama with short keep_alive). Residency when unloaded is
effectively zero (warm page cache only); when loaded, expect roughly the
quant file size pinned in GTT plus a few GB of KV/compute. Don't rely on
swap/zram to paper over a loaded model: GTT-pinned pages can't be
swapped or compressed, so process-exit unloading is strictly better.

## 4. Tool-calling quality in an agentic harness

**Plumbing is now first-class, no proxy needed.** llama.cpp's server
merged native Anthropic `/v1/messages` support (streaming, tool_use /
tool_result, `count_tokens`, thinking) in Jan 2026
([PR #17570](https://github.com/ggml-org/llama.cpp/pull/17570),
[announcement](https://huggingface.co/blog/ggml-org/anthropic-messages-api-in-llamacpp)):
`llama-server -hf <model> --jinja` +
`ANTHROPIC_BASE_URL=http://127.0.0.1:8080` and Claude Code just works.
ollama v0.14+ likewise speaks `/v1/messages` natively and documents the
Claude Code setup, recommending ≥32K context
([ollama blog](https://ollama.com/blog/claude); known
`count_tokens?beta=true` hang,
[#13949](https://github.com/ollama/ollama/issues/13949)). llama-swap
proxies `/v1/messages` through, so model-swapping and Claude Code
compose. The 2025-era proxies are now legacy: claude-code-router had a
transformer bug that corrupted streamed Qwen3 tool-call deltas
([#1397](https://github.com/musistudio/claude-code-router/issues/1397));
LiteLLM-as-anthropic-proxy still works
([recipe](https://gist.github.com/WolframRavenwolf/0ee85a65b10e1a442e4bf65f848d6b01)).
Claude Code fires parallel background requests (haiku-model calls,
count_tokens), so provision `--parallel` slots on a single local server
([writeup](https://dev.to/mfolsom/the-ghost-in-the-cli-why-claude-code-kills-local-inference-dfc)).

**Model quality.** llama.cpp has native tool-call grammar handlers for
the Qwen/Llama/Mistral/GPT-OSS families (`--jinja` required; KV-cache
quantization "can substantially degrade tool calling"
— [function-calling.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md)).
Benchmark standing of models that fit this machine:

- **GLM-4.7-Flash (30B-A3B MoE, Jan 2026, MIT)** — ~59% SWE-bench
  Verified; the model both the llama.cpp and ollama teams demo Claude
  Code with ([release coverage](https://www.marktechpost.com/2026/01/20/zhipu-ai-releases-glm-4-7-flash-a-30b-a3b-moe-model-for-efficient-local-coding-and-agents/)).
- **Qwen3-Coder-30B-A3B** — RL-trained for agentic coding, dedicated
  function-call format, ~50% SWE-bench V
  ([model card](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct)).
  Known wart: silently drops optional tool params past ~30K context.
- **gpt-oss-20b** — fast, tool-capable (τ-bench Retail ~55%), weaker
  coder ([model card](https://cdn.openai.com/pdf/419b6906-9da6-406c-a19d-1bb078ac7637/oai_gpt-oss_model_card.pdf)).
- **Devstral Small 24B** — 53.6% SWE-bench V but tuned for OpenHands
  specifically ([mistral.ai](https://mistral.ai/news/devstral-2507/)).
- Dense Qwen3-32B is a worse agentic coder than the MoEs at equal RAM
  (40.0 Aider polyglot, [llm-stats](https://llm-stats.com/benchmarks/aider))
  — and 7× slower here (§2).

**Reliability caveats:** tool-calling degrades *before* chat quality
under quantization — Q4_K_M weights are the practical floor, keep KV
cache unquantized
([measurement](https://dev.to/happynood/does-quantization-break-tool-calling-i-measured-it-on-a-4gb-laptop-gpu-bfcl-3-seeds-bootstrap-185l)).
Expect roughly Claude-3.5-Sonnet-era competence: real multi-turn agent
work with supervision, occasional malformed-call retries on long
sessions — not chat-only, but not unattended either.

## 5. Verdict

**What the local tier can credibly serve:**

- **Sensitive-content / private chat: yes, comfortably.** 20+ tok/s
  from a 30B-A3B MoE is fully interactive, and the content never
  leaves the laptop. This is the strongest use case.
- **Coding-agent (Claude Code against local): yes, with supervision
  and modest scope.** The plumbing is now first-class (native
  `/v1/messages` in llama.cpp/ollama, llama-swap passes it through).
  Qwen3-Coder-30B-A3B / GLM-4.7-Flash land ~50–59% SWE-bench Verified —
  real agentic capability, roughly Sonnet-3.5-era. Expect occasional
  malformed tool calls, degradation past ~30K context, and the need to
  provision parallel server slots for Claude Code's background
  requests. Good for private repos / airplane mode / small scoped
  tasks; not a replacement for the hosted tier on long or hard
  sessions.
- **Chat-only fallback models: unnecessary** — the models worth
  loading at all are the agent-capable MoEs; dense 32B-class models
  are both slower (~3 t/s) and weaker here, so skip them entirely.

**Costs:**

- **RAM:** ~20–26 GB GTT pinned while a Q4–Q6 30B-A3B model + KV is
  loaded; effectively zero when llama-swap's TTL expires (process
  exit frees GTT; mmap'd weights linger only as evictable page
  cache). Fine on 64 GB as long as unload is automatic.
- **Config:** small and additive — `services.llama-swap` + a
  `llama-cpp-vulkan` model entry (or `services.ollama` with
  `package = pkgs.ollama-vulkan` and `OLLAMA_KEEP_ALIVE` short). No
  kernel params, no HSA overrides, no BIOS changes needed at this
  model size. Everything required is already in the `nixos-26.05` pin.
- **Battery/thermals:** generation saturates the memory bus and iGPU;
  this is a plugged-in workload (not separately benchmarked here).
- **Capability ceiling:** hard-bounded by ~90 GB/s memory bandwidth.
  The next real step up is Strix Halo-class hardware (256 GB/s,
  128 GB), not config tuning — though the 96 GB SO-DIMM option would
  at least admit gpt-oss-120b at single-digit t/s.

**Suggested shape if implemented:** `services.llama-swap` with
Qwen3-Coder-30B-A3B (or GLM-4.7-Flash) Q4_K_M via `llama-cpp-vulkan`,
`ttl` ~600 s, bound to localhost; `ANTHROPIC_BASE_URL` pointed at it
for private Claude Code sessions. Keep KV cache unquantized; keep
weights ≥Q4_K_M.
