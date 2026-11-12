# Changelog

## 1.1.0 — 2026-11-12

- **Every major provider as a first-class backend:** `anthropic` (Claude, native `/v1/messages` with `x-api-key` +
  `anthropic-version: 2026-10-21`, because Anthropic's OpenAI-compatible endpoint forwards `temperature`, which current
  Claude models reject), `gemini`, `xai` (Grok), `mistral`, `deepseek` and `meta` (Meta Model API, Meta's current
  developer API), all on the OpenAI chat-completions path except Claude. Each needs its own Keychain key and https, and
  comes after the local backends in Auto. Defaults: `claude-sonnet-5-5` (fallback list adds `claude-haiku-5-5`),
  `gemini-3.8-flash`, `grok-4.7`, `mistral-small-latest`, `deepseek-flash`, `muse-spark-1.3`.
- **OpenAI:** default model `gpt-6-luna` (was `gpt-4o-mini`); requests send `max_completion_tokens` and no
  `temperature`, which OpenAI's reasoning models require.
- **Per-request override:** `NovaAIRequest(prompt:system:…backend:model:)`. A request with `backend` goes to exactly that
  backend and model, with no failover, using the URL and key from settings. New `NovaAIModelPicker(ai:title:backend:model:)`
  for per-side picks in model-vs-model games; new `NovaAI.availableBackends`.
- **No Nova:** `NovaAISettings.allowNova` / `NovaAI.allowNova` (default `true`). When it's off, Auto skips Nova Gateway,
  and any request for it fails fast with the new `NovaAIError.novaDisabled`, sending nothing. Nova is never probed or
  listed, and it's hidden from pickers. There's a toggle in `NovaAISettingsView`. Settings saved by 1.0 decode with
  `allowNova = true`.
- Legacy names: "Claude", "Gemini", "Grok", "Llama API", "ChatGPT" map to the new backends. The removed stubs
  (Google Cloud AI, Azure, AWS, IBM Watson) still map to Auto.
- Anthropic replies and SSE streams are parsed (thinking blocks skipped). Gemini gets `reasoning_effort: low` unless
  `reasoning` is set.
- 145 tests (was 113) in 7 categories; zero warnings on macOS, iOS and tvOS.

## 1.0.0 — 2026-11-11

First release: the shared AI feature set, extracted from the converged game code (CarTest NovaAI/LLMBalancerManager,
StuntDriver LLMClient, GTNW Retry, BlompieTV LLMBalancerManager, Blompie Services/*).

- Backends: auto, ollama, mlx, tinyllm, tinychat, openwebui, novagateway, openrouter, openai (Google/Azure/AWS/IBM
  dropped — they were stubs). Auto failover in a fixed order, per-backend bounded retries with backoff, 60 s skip of
  failed servers, per-attempt timeouts.
- `NovaAI` observable façade: on/off toggle (persisted), never-throwing `generate/text/structured` with app fallback and
  validator (one retry with the rejection reason), throwing drop-in `generate(prompt:systemPrompt:temperature:maxTokens:)`,
  multi-turn `chat`, streaming (Ollama NDJSON, OpenAI SSE, `<think>` filtered across chunks), JSON / JSON-schema output.
- Keys only in the Keychain (`com.jkoch.<appid>.<backend>`, account `apiKey`); https-only for any keyed request
  (loopback http allowed only for OpenWebUI's optional key); migration from old Keychain items and plaintext
  UserDefaults (write verified before anything is deleted); purge of removed backends' secrets and the old guardian
  prompt log.
- Nova Gateway: OpenAI path (fleet router / Rosetta / any compatible server) with automatic fallback to the Gateway V2
  `/api/chat` API.
- Ollama `think` off by default (`NovaAIRequest.reasoning` to opt in).
- SwiftUI `NovaAISettingsView` and `NovaAIStatusIndicator` (macOS 12+, iOS 15+, tvOS 15+).
- Optional `NovaAIKitMLX`: `NovaAIMLXServer` (mlx_lm.server on loopback) and `NovaAIClosureModel` (plug an in-process engine).
- 113 tests in 7 categories; zero warnings on macOS, iOS and tvOS.
