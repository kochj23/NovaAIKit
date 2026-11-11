# Changelog

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
