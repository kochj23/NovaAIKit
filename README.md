# NovaAIKit

One AI feature set for every app. NovaAIKit is a Swift package that gives a macOS, iOS or tvOS app the same AI
options and behaviour as every other app in the family: an on/off switch, a scripted fallback, fifteen backends (local servers and every major cloud provider) with
Auto failover, keys kept in the Keychain, a status indicator, output validation, structured output, streaming, and a
drop-in settings screen. Each app adds the package in place of its own copy of the AI code.

- **Version:** 1.1.0
- **Platforms:** macOS 12+, iOS 15+, tvOS 15+. These are the lowest deployment targets Xcode 27 can still build, and
  they cover every adopting app. GTNW iOS is 15. Stream Rotator and RTSP Rotator declare macOS 11, which Xcode 27
  rejects, so they move to 12.0 when they adopt.
- **Swift:** tools 6.0, Swift 6 language mode, Sendable-correct, zero warnings. Apps in Swift 5 mode can use it.
- **Dependencies:** none.
- **How to migrate an app:** see [ADOPTION.md](ADOPTION.md).

## Features

| # | Feature | How |
|---|---|---|
| 1 | AI on/off, saved per app | `ai.isEnabled` / `settings.enabled`. When it's off, nothing is sent and every caller gets its fallback. |
| 2 | Scripted fallback | `generate(_:validate:fallback:)`, `text(_:fallback:)` and `structured(_:_:fallback:)` never throw. The fallback closure is the app's own. A failed call can't block the app. |
| 3 | Backends, model picker, editable URLs | `auto, ollama, mlx, tinyllm, tinychat, openwebui, novagateway, openrouter, openai, anthropic, gemini, xai, mistral, deepseek, meta`. `listModels(for:)` asks the backend for its models. Every URL can be edited; local ones default to localhost, cloud ones to the provider's https API. |
| 4 | Keys only in the Keychain | Service `com.jkoch.<appid>.<backend>`, account `apiKey`. Keys are never stored in UserDefaults, the environment or files. One-time migration helpers move keys from old Keychain items and from plaintext UserDefaults. |
| 5 | https only for keys | A request that carries a key is refused before it's sent unless it uses https. Every cloud backend (OpenRouter, OpenAI, Anthropic, Gemini, xAI, Mistral, DeepSeek, Meta) always needs https. OpenWebUI's optional key may also go over plain http to this machine (loopback). |
| 6 | Observable status | `ai.status` holds the active backend, host, model, reachability per backend, last error, latency and where the last answer came from. `NovaAIStatusIndicator` shows it in SwiftUI. |
| 7 | Auto failover | Fixed order: Ollama → MLX → TinyChat → TinyLLM → OpenWebUI → Nova Gateway → OpenRouter → OpenAI → Anthropic → Gemini → xAI → Mistral → DeepSeek → Meta. Cloud backends join only when their key is stored; Nova Gateway only when `allowNova` is on. Each request has a timeout. A backend gets bounded retries with backoff (408/429/5xx). A server that just failed is skipped for 60 s. |
| 8 | Output validation | The app's validator rejects a reply by throwing, or clamps it by returning a corrected value. After a rejection the kit asks once more and passes on the reason, then uses the fallback. |
| + | Streaming | `stream(_:)` yields text deltas: Ollama NDJSON or OpenAI SSE. `<think>` blocks are removed, even when a tag is split across chunks. |
| + | Structured output | `structured(T.self, request, schema:)` sends a native JSON schema where the backend supports one (Ollama `format`, OpenAI/OpenRouter `response_format`). Otherwise the schema goes in the prompt. The reply is then decoded and validated. |
| + | Drop-in settings | `NovaAISettingsView(ai:)` has the toggle, backend and timeout pickers, URL and model per backend, a model list, SecureField key entry (saved to the Keychain, never shown) and Test connection. |
| + | Nova fleet | The `novagateway` backend speaks OpenAI `/v1/chat/completions`, which covers the fleet inference router, Rosetta and any OpenAI-compatible server. If a URL answers 404, the kit switches to the Nova Gateway V2 API (`/api/chat` with `person: "service"`) and remembers that for the URL. |
| + | Per-request override | `NovaAIRequest(…, backend: .anthropic, model: "claude-haiku-5-5")` sends that one request to exactly that backend and model (no failover), with the URL and key from settings. `NovaAIModelPicker` picks a backend + model per side for model-vs-model games. |
| + | No Nova | `settings.allowNova = false` (or `ai.allowNova`): Auto skips Nova Gateway, and a request that names it fails fast with `NovaAIError.novaDisabled`. Every other backend works without Nova. Toggle is in `NovaAISettingsView`. |
| + | Legacy drop-ins | `generate(prompt:systemPrompt:temperature:maxTokens:)` has the same signature as the old `AIBackendManager.shared.generate`. `migrateFromLegacyAIBackendManager()` imports the old settings and keys and deletes obsolete secrets. |

Google Cloud (Vertex), Azure, AWS and IBM Watson are left out on purpose. They were stubs that never worked. Gemini,
Claude, Grok, Mistral, DeepSeek and Meta are real first-class backends since 1.1.0, each with its own Keychain key.

## Architecture

```mermaid
flowchart LR
    subgraph App
        V[SwiftUI views] -->|NovaAISettingsView<br/>NovaAIStatusIndicator| AI
        F[Feature code<br/>summaries · chat · extraction · game AI] -->|generate / text / structured / stream| AI
        FB[App fallback + validator] -.-> AI
    end
    subgraph NovaAIKit
        AI["NovaAI (@MainActor, ObservableObject)<br/>settings · status · toggle · validate→retry→fallback"]
        AI --> E["NovaAIEngine (Sendable)<br/>candidates · retry · failover · stream · probe"]
        AI --> K["NovaAIKeys<br/>Keychain com.jkoch.appid.backend"]
        AI --> S[(NovaAISettingsStorage<br/>UserDefaults blob, no secrets)]
        E --> H[NovaAIHealth<br/>skip failed URLs 60 s]
        E --> W["NovaAIWire<br/>Ollama · OpenAI · Gateway native<br/>https-only key rule"]
        E -.->|optional| L[NovaAILocalModel<br/>in-process MLX]
    end
    W --> O[Ollama :11434]
    W --> M[mlx_lm.server :8081]
    W --> T[TinyChat / TinyLLM :8000]
    W --> OW[OpenWebUI :8080]
    W --> G[Nova Gateway :18792<br/>fleet router / Rosetta]
    W -->|https + Bearer| OR[OpenRouter]
    W -->|https + Bearer| OC["OpenAI · Gemini · xAI<br/>Mistral · DeepSeek · Meta"]
    W -->|https + x-api-key| AN[Anthropic /v1/messages]
    subgraph NovaAIKitMLX [NovaAIKitMLX, optional]
        MS[NovaAIMLXServer<br/>start/stop mlx_lm.server] --> M
        CM[NovaAIClosureModel] --> L
    end
```

### Failover sequence (Auto)

```mermaid
sequenceDiagram
    participant App
    participant AI as NovaAI
    participant E as NovaAIEngine
    participant O as Ollama
    participant X as MLX server
    participant R as OpenRouter (key in Keychain)
    App->>AI: generate(request, validate, fallback)
    alt AI off
        AI-->>App: fallback() · source .fallback(.disabled) — nothing sent
    end
    AI->>E: complete(request)
    E->>E: candidates (Auto order, keyed only with a key), skip URLs that failed within 60 s
    E->>O: POST /api/chat (timeout)
    O-->>E: 503
    E->>E: backoff 0.5 s (retryable)
    E->>O: POST /api/chat
    O-->>E: connection refused → mark down, fail over
    E->>X: POST /v1/chat/completions
    X-->>E: timeout → fail over (no retry)
    E->>R: POST https://…/chat/completions + Bearer
    R-->>E: 200 reply
    E-->>AI: NovaAIResponse(backend: .openRouter)
    AI->>AI: validate(reply)
    alt rejected
        AI->>R: same conversation + the rejection reason
        R-->>AI: reply 2
        AI->>AI: validate again → else fallback()
    end
    AI-->>App: NovaAIResult(value, source: .ai / .fallback)
```

## Per-request override (model vs model)

Each request can name its own backend and model. That request then goes to exactly that backend and model: no Auto
failover, no other backend, but still the URL and the Keychain key from settings. Two sides of a game can each use a
different provider and model:

```swift
@State var whiteBackend: NovaAIBackend = .anthropic
@State var whiteModel = "claude-sonnet-5-5"
@State var blackBackend: NovaAIBackend = .openAI
@State var blackModel = "gpt-6-luna"

Form {
    NovaAIModelPicker(ai: AppAI.shared, title: "White", backend: $whiteBackend, model: $whiteModel)
    NovaAIModelPicker(ai: AppAI.shared, title: "Black", backend: $blackBackend, model: $blackModel)
}

let move = await AppAI.shared.text(NovaAIRequest(prompt: position, system: rules,
                                                 backend: whiteBackend, model: whiteModel)) { engineMove() }
```

`NovaAIModelPicker` lists `ai.availableBackends` (plus "Settings", which is `.auto`, meaning no override) and the
backend's models from `listModels(for:)`, falling back to `fallbackModels`. A missing key gives `.missingKey(backend)`
and the app's fallback, never another provider.

```mermaid
flowchart TD
    R[NovaAIRequest] --> Q{request.backend set<br/>and not .auto?}
    Q -->|yes| ONE["exactly that backend<br/>model = request.model ?? settings model<br/>URL + key from settings"]
    Q -->|no| S{settings.backend}
    S -->|concrete| ONE2[that backend]
    S -->|.auto| AUTO[autoOrder]
    AUTO --> NN{allowNova?}
    NN -->|no| SKIP[drop Nova Gateway]
    NN -->|yes| KEEP[keep it]
    SKIP --> KEYS[keyed backends only with a Keychain key]
    KEEP --> KEYS
    ONE --> NC{Nova Gateway and<br/>allowNova off?}
    ONE2 --> NC
    NC -->|yes| ERR[throw .novaDisabled<br/>nothing sent]
    NC -->|no| SEND[retries on that backend only]
    KEYS --> FAIL[failover in order]
```

## No Nova

Every app runs with no dependency on Nova. `settings.allowNova` (default `true`; `ai.allowNova` on `NovaAI`, and a
"Allow Nova" toggle in `NovaAISettingsView`) controls the one Nova-specific backend, `novagateway`:

| `allowNova` | Auto | `backend == .novaGateway` (setting or request) | Probes, model list, pickers |
|---|---|---|---|
| `true` (default) | tries Nova Gateway after the local servers | sent to the gateway URL | normal |
| `false` | skips Nova Gateway, goes on to the cloud backends | fails fast with `NovaAIError.novaDisabled`, nothing sent | Nova never probed or listed; hidden from pickers |

Nothing else in the kit needs Nova: Ollama, MLX, TinyChat, TinyLLM, OpenWebUI and the cloud providers are all direct.
Settings saved by 1.0 decode with `allowNova = true`.

## Install (Swift Package Manager)

**Package.swift**

```swift
.package(url: "https://github.com/kochj23/NovaAIKit.git", from: "1.1.0"),
// target:
.product(name: "NovaAIKit", package: "NovaAIKit"),
// optional, macOS: .product(name: "NovaAIKitMLX", package: "NovaAIKit"),
```

**XcodeGen (`project.yml`)**

```yaml
packages:
  NovaAIKit:
    url: https://github.com/kochj23/NovaAIKit.git
    from: 1.1.0
targets:
  MyApp:
    dependencies:
      - package: NovaAIKit
        product: NovaAIKit
```

**Plain `.xcodeproj`:** run `ruby scripts/add-novaaikit.rb MyApp.xcodeproj MyApp`, or in Xcode use File > Add Package
Dependencies… and enter the URL. The package URL is the public https one, so it needs no credentials.

## Quick start

```swift
import NovaAIKit

@MainActor enum AppAI {
    static let shared: NovaAI = {
        let ai = NovaAI(configuration: NovaAIConfiguration(appID: "newssummary", appName: "News Summary"))
        ai.migrateFromLegacyAIBackendManager()                       // old UserDefaults settings + plaintext key
        ai.migrateLegacyKey(service: "com.jordankoch.NewsSummary.AIBackend", account: "openAIAPIKey", to: .openAI)
        return ai
    }()
}

// Throwing, drop-in for the old manager:
let summary = try await AppAI.shared.generate(prompt: text, systemPrompt: "Summarize.", temperature: 0.3, maxTokens: 300)

// Never throws: AI → validated → else the app's own answer.
let r = await AppAI.shared.text(NovaAIRequest(prompt: prompt, system: sys)) { builtInSummary }
label.text = r.value          // r.source.label → "AI · Ollama (qwen3:8b)" or "Built-in"

// Structured extraction with a schema and a clamp:
struct Triage: Codable, Sendable { var category: String; var priority: Int }
let schema = try NovaAIJSONSchema(name: "triage", json: #"{"type":"object","required":["category","priority"],"properties":{"category":{"type":"string"},"priority":{"type":"integer"}}}"#)
let t = await AppAI.shared.structured(Triage.self, NovaAIRequest(prompt: email), schema: schema,
                                      validate: { var t = $0; t.priority = min(max(t.priority, 1), 5); return t },
                                      fallback: { Triage(category: "other", priority: 3) })

// Streaming chat:
for try await delta in AppAI.shared.stream(NovaAIRequest(messages: history)) { output += delta }

// SwiftUI:
NovaAISettingsView(ai: AppAI.shared, footer: "When AI is off, summaries use the first paragraph.")
NovaAIStatusIndicator(ai: AppAI.shared)
```

## API summary

| Type | Role | Key members |
|---|---|---|
| `NovaAI` | `@MainActor ObservableObject`, the app's one object | `init(configuration:storage:keyStore:session:sleep:localModel:)`, `settings`, `status`, `isEnabled`, `allowNova`, `availableBackends`, `complete(_:)`, `generate(prompt:systemPrompt:temperature:maxTokens:)`, `chat(_:)`, `stream(_:)`, `streamEvents(_:)`, `generate(_:validate:fallback:)`, `text(_:validate:fallback:)`, `structured(_:_:schema:validate:fallback:)`, `refreshStatus()`, `testConnection(_:)`, `listModels(for:)`, `setAPIKey(_:for:)`, `hasAPIKey(for:)`, `migrateLegacyKey(service:account:to:deleteLegacy:legacyStore:)`, `migrateLegacyDefaultsKey(_:defaults:to:)`, `migrateLegacySettings(from:)`, `migrateFromLegacyAIBackendManager(defaults:)` |
| `NovaAIConfiguration` | Fixed per-app facts | `appID`, `appName`, `appURL`, `keychainAccessGroup`, `defaultSettings`, `retry`, `probeTimeout`, `healthTTL`, `maxInputCharacters`, `maxOutputCharacters`, `keychainService(for:)` |
| `NovaAISettings` | User settings (no secrets), Codable, decodes tolerantly | `enabled`, `allowNova`, `backend`, `url(for:)`/`setURL`, `model(for:)`/`setModel`, `extraOllamaEndpoints`, `timeout` |
| `NovaAIBackend` | Canonical ids | `autoOrder`, `selectable`, `displayName`, `defaultURL`, `defaultModel`, `fallbackModels`, `requiresKey`, `acceptsKey`, `speaksAnthropic`, `supportsJSONSchema`, `chatPath`, `modelsPath`, `init?(legacyName:)` |
| `NovaAIRequest` / `NovaAIMessage` | Input | `init(prompt:system:temperature:maxTokens:format:backend:model:)`, `init(messages:…backend:model:timeout:reasoning:)`; `backend`/`model` are the per-request override |
| `NovaAIResponseFormat` / `NovaAIJSONSchema` | Structured output | `.text`, `.json`, `.jsonSchema(schema)`. Schemas come from a JSON string or a dictionary. |
| `NovaAIResponse` | Successful answer | `text`, `backend`, `model`, `endpoint`, `latency`, `attempts` |
| `NovaAIResult<T>` / `NovaAISource` | Answer from the never-throwing API | `value`, `source` (`.ai(backend:model:)` / `.fallback(reason)`), `response`, `source.label` |
| `NovaAIError` / `NovaAIValidationError` | Errors (key-free) | `.disabled`, `.novaDisabled`, `.missingKey`, `.insecureTransport`, `.httpStatus`, `.timedOut`, `.allBackendsFailed`… |
| `NovaAIStatus` | Observable status | `state` (`off/unknown/checking/online/offline`), `activeBackend`, `host`, `reachability`, `lastError`, `lastLatency`, `lastSource`, `label` |
| `NovaAIEngine` | Sendable network engine (usable off the main actor, e.g. CLIs) | `candidates`, `complete`, `stream`, `probe`, `probeAll`, `listModels` |
| `NovaAIKeys`, `NovaAIKeychain`, `NovaAIMemoryKeyStore` | Secrets | `key(for:)`, `setKey`, `migrateLegacyKey`, `migrateLegacyDefaultsKey`, `deleteObsoleteLegacyItems(service:)` |
| `NovaAIUserDefaultsStorage`, `NovaAIMemoryStorage`, `NovaAISettingsStorage` | Settings persistence | Implement the protocol to keep settings elsewhere (e.g. a database). |
| `NovaAILegacySettings` | Old `AIBackendManager` UserDefaults keys | `read(from:base:)`, `removeObsoleteKeys(from:)` |
| `NovaAIRetryPolicy`, `NovaAIRetry`, `NovaAIHealth` | Resilience | default 2 attempts/backend, 0.5 s base, ×2, max 4 s; health TTL 60 s |
| `NovaAIText` | Pure helpers | `clean`, `jsonPayload`, `decode`, `numbers`, `grounded`, `plain`, `listItems` |
| `NovaAILocalModel` | Plug an in-process engine into `mlx` | `isAvailable()`, `complete(messages:temperature:maxTokens:)` |
| `NovaAISettingsView`, `NovaAIStatusIndicator`, `NovaAIModelPicker` | SwiftUI | drop-in views; `NovaAIModelPicker(ai:title:backend:model:)` is the per-side backend + model picker |
| `NovaAIMLXServer`, `NovaAIClosureModel` (NovaAIKitMLX) | Optional MLX | start/stop `mlx_lm.server` on loopback; wrap any closure as a local model |

## Backends

| id | Default URL | Chat path | Models path | Key |
|---|---|---|---|---|
| `ollama` | http://localhost:11434 | /api/chat | /api/tags | none |
| `mlx` | http://localhost:8081 | /v1/chat/completions | /v1/models | none (or in-process) |
| `tinychat` | http://localhost:8000 | /api/chat/stream | / | none |
| `tinyllm` | http://localhost:8000 | /v1/chat/completions | /v1/models | none |
| `openwebui` | http://localhost:8080 | /api/chat/completions | /api/models | optional |
| `novagateway` | http://127.0.0.1:18792 | /v1/chat/completions → /api/chat | /v1/models | none |
| `openrouter` | https://openrouter.ai/api/v1 | /chat/completions | /models | required, https |
| `openai` | https://api.openai.com/v1 | /chat/completions | /models | required, https |
| `anthropic` | https://api.anthropic.com/v1 | /messages (native) | /models | required, https |
| `gemini` | https://generativelanguage.googleapis.com/v1beta/openai | /chat/completions | /models | required, https |
| `xai` | https://api.x.ai/v1 | /chat/completions | /models | required, https |
| `mistral` | https://api.mistral.ai/v1 | /chat/completions | /models | required, https |
| `deepseek` | https://api.deepseek.com | /chat/completions | /models | required, https |
| `meta` | https://api.meta.ai/v1 | /chat/completions | /models | required, https |

### Cloud providers

All provider facts were checked against each provider's docs on 2026-11-12. The model list in the picker comes live
from the provider (`/models`); the defaults below are used until the user picks one, and the fallbacks when the list
can't be fetched.

| Backend | Provider | Auth header | Default model | Fallback models | Native JSON schema | Notes |
|---|---|---|---|---|---|---|
| `openai` | OpenAI (ChatGPT) | `Authorization: Bearer` | `gpt-6-luna` | `gpt-6-luna`, `gpt-6-astra` | yes | Sends `max_completion_tokens` and no `temperature` (reasoning models reject both `max_tokens` and non-default temperatures). |
| `anthropic` | Anthropic Claude | `x-api-key` + `anthropic-version: 2026-10-21` | `claude-sonnet-5-5` | `claude-sonnet-5-5`, `claude-haiku-5-5`, `claude-opus-5-5` | yes (`output_config.format`) | Native Messages API: Anthropic's OpenAI-compatible endpoint forwards `temperature`, which current Claude models reject. System prompt goes to `system`; `output_config.effort` is `low` (or `high` with `reasoning: true`). |
| `gemini` | Google Gemini | `Authorization: Bearer` | `gemini-3.8-flash` | `gemini-3.8-flash`, `gemini-3.5-flash-lite`, `gemini-3.1-pro-preview` | yes | OpenAI-compatible endpoint; `reasoning_effort: low` unless `reasoning: true`. |
| `xai` | xAI Grok | `Authorization: Bearer` | `grok-4.7` | `grok-4.7`, `grok-build-0.1` | yes | |
| `mistral` | Mistral AI | `Authorization: Bearer` | `mistral-small-latest` | `mistral-small-latest`, `mistral-large-latest` | yes | |
| `deepseek` | DeepSeek | `Authorization: Bearer` | `deepseek-flash` | `deepseek-flash`, `deepseek-v4-pro` | no (schema in the prompt) | `deepseek-chat`/`deepseek-reasoner` were deprecated on 2026-07-24. |
| `meta` | Meta Model API | `Authorization: Bearer` | `muse-spark-1.3` | `muse-spark-1.3`, `muse-ember-1.0`, `muse-wonder-1.0` | no (schema in the prompt) | Meta's current developer API (`api.meta.ai`, Muse models); its docs no longer list the Llama API. OpenAI-compatible. |
| `openrouter` | OpenRouter | `Authorization: Bearer` + `HTTP-Referer`/`X-Title` | `anthropic/claude-sonnet-4.5` | as before | yes | One key for many providers. |

Each key lives in the Keychain under `com.jkoch.<appID>.<backend>` and is sent only to that backend's configured URL,
only over https. A request for one provider never carries another provider's key (tested).

**Legacy names.** `init?(legacyName:)` maps "Claude" → `anthropic`, "Gemini"/"Google Gemini" → `gemini`, "Grok" →
`xai`, "Llama"/"Llama API"/"Meta Llama" → `meta`, "ChatGPT" → `openai`. The old stubs "Google Cloud AI", "Microsoft
Azure", "AWS AI Services" and "IBM Watson" still map to **Auto**, not to Gemini: the Google Cloud stub was Vertex and had
no working key to carry over, and Auto keeps such an app working with no setup.

Extra Ollama-compatible servers can be listed in `settings.extraOllamaEndpoints` (LAN hosts, the fleet router) and
are tried after the primary Ollama URL. On Ollama, `think` is false unless the request sets `reasoning: true`. That
stops a reasoning model from spending the whole token budget thinking and returning an empty answer. Any `<think>`
block that still comes back is removed.

### MLX choice

The core `mlx` backend talks over HTTP to `mlx_lm.server` (OpenAI-compatible). mlx-swift is **not** a dependency, for
two reasons: it needs a Metal shader build that plain `swift build`/`swift test` can't do, and it would raise the
minimum to macOS 14, which the macOS 12/13 apps can't adopt. The optional **NovaAIKitMLX** product adds two things:

- `NovaAIMLXServer` starts `python3 -m mlx_lm.server` bound to 127.0.0.1 and stops it again.
- `NovaAIClosureModel` wraps any in-process engine as a `NovaAILocalModel`. An app that already links mlx-swift (such
  as MLX Code) plugs its engine into the `mlx` backend this way.

## Keychain naming

| Item | Value |
|---|---|
| Service | `com.jkoch.<appID>.<backend>`, e.g. `com.jkoch.mailsummary.openrouter` |
| Account | `apiKey` |
| Accessibility | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| Access group | `NovaAIConfiguration.keychainAccessGroup`: nil means the login/app keychain; set it for the Data Protection keychain |

Updates are made in place, so the item's ACL survives. Saving an empty value deletes the item. Keys are trimmed and
never logged, and never appear in settings, status or errors (there are tests for this).

## Tests

```
swift test
```

| Category | File | Tests |
|---|---|---|
| Unit | `UnitTests.swift` | 39 |
| Security | `SecurityTests.swift` | 23 |
| Retry | `RetryTests.swift` | 17 |
| Functional | `FunctionalTests.swift` | 37 |
| Performance | `PerformanceTests.swift` | 12 |
| Frame / UI state | `FrameTests.swift` | 12 |
| Integration (live local Ollama; skips when unreachable) | `IntegrationTests.swift` | 5 |
| **Total** | | **145** |

The network is stubbed with a `URLProtocol` (`Support.swift`), and the tests use in-memory key and settings stores.
No real key is ever used. The one real-Keychain test uses a throwaway service, deletes it afterwards, and skips if no
keychain is available. The integration tests use the local Ollama when it's reachable; `NOVAAIKIT_TEST_MODEL` picks
the model. The package also builds with zero warnings for macOS, iOS and tvOS (`xcodebuild -scheme NovaAIKit-Package
-destination 'generic/platform=iOS' build`).

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT. Copyright © 2026 Jordan Koch.
