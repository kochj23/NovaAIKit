# Adopting NovaAIKit in an existing app

Follow these steps in order. Each step names the exact thing to do. Do not skip the checks at the end of each step.
The goal: the app keeps every AI feature it really had, gains the full NovaAIKit feature set, and keeps no AI
client code of its own.

**Rules that always apply**

- Work in a fresh clone of the app's repo, never in the NAS copy. Commit with explicit paths and end each commit with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- No secret goes into source, UserDefaults, the environment or files. Keys go only through
  `NovaAI.setAPIKey` / the migration helpers.
- Never print or log a key, or the contents of a Keychain item.
- Use NovaAIKit `from: 1.0.0` (up to the next major version).

---

## Step 0: Inventory (read only)

Run these from the app's repo root and keep the output. You'll need it in steps 3, 5 and 7.

```bash
# AI client code (candidates for deletion in step 7)
grep -rlE "AIBackendManager|AIBackendStatusMenu|EthicalAIGuardian|OllamaClient|OllamaService|LLMClient|LLMBalancerManager|OpenRouterProvider|AICapabilities|/api/chat|/api/generate|chat/completions" --include='*.swift' .
# Call sites to replace in step 5
grep -rnE "AIBackendManager\.shared\.[a-zA-Z]+|AIBackendManager\(\)|aiBackend\.generate|\.generateWithFallback" --include='*.swift' .
# Old Keychain services and accounts (step 3)
grep -rnE "keychainService|kSecAttrService|kSecAttrAccount|saveToKeychain\(key:" --include='*.swift' .
# Old UserDefaults keys (step 3)
grep -rhoE 'forKey: *"[^"]+"' --include='*.swift' . | sort -u | grep -iE "ai|backend|ollama|llm|model|openai|key"
# Deployment target (must be macOS >= 12, iOS >= 15, tvOS >= 15; raise 11.0 to 12.0 — Xcode 27 can't build 11)
grep -rhoE "(MACOSX|IPHONEOS|TVOS)_DEPLOYMENT_TARGET = [0-9.]+" --include=project.pbxproj . | sort -u
```

Write down:

1. Which features use AI and what each one does when AI fails today: summary, chat, extraction/classification,
   naming, game logic.
2. Whether the app has its own Keychain access group (look for `kSecAttrAccessGroup` / `keychain-access-groups`).
3. Whether the app keeps its AI settings somewhere other than UserDefaults. CarTest, for example, keeps them in the
   games DB.

## Step 1: Add the package

### 1a. Apps with `project.yml` (XcodeGen)

Add this to `project.yml`. Merge it with an existing `packages:` key if there is one:

```yaml
packages:
  NovaAIKit:
    url: https://github.com/kochj23/NovaAIKit.git
    from: 1.0.0
```

Add the dependency to the app target, and to every other target that calls AI (widgets, CLIs, extensions):

```yaml
targets:
  <AppTarget>:
    dependencies:
      - package: NovaAIKit
        product: NovaAIKit
      # MLX Code only (in-process MLX or launching mlx_lm.server):
      # - package: NovaAIKit
      #   product: NovaAIKitMLX
```

Then run `xcodegen generate` and commit **both** `project.yml` and the regenerated `.xcodeproj`.

### 1b. Apps with only an `.xcodeproj` (pbxproj)

```bash
gem list xcodeproj | grep -q xcodeproj || gem install xcodeproj
curl -fsSLo /tmp/add-novaaikit.rb https://raw.githubusercontent.com/kochj23/NovaAIKit/1.0.0/scripts/add-novaaikit.rb
ruby /tmp/add-novaaikit.rb "<App>.xcodeproj" "<AppTarget>" [<OtherTarget> …] [--mlx]
```

The script is idempotent. It adds the following to `project.pbxproj`:

```
/* in PBXProject */            packageReferences = ( XXXX /* XCRemoteSwiftPackageReference "NovaAIKit" */, );
/* XCRemoteSwiftPackageReference */
    XXXX = { isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/kochj23/NovaAIKit.git";
             requirement = { kind = upToNextMajorVersion; minimumVersion = 1.0.0; }; };
/* XCSwiftPackageProductDependency */
    YYYY = { isa = XCSwiftPackageProductDependency; package = XXXX; productName = NovaAIKit; };
/* in the target */            packageProductDependencies = ( YYYY /* NovaAIKit */, );
/* PBXBuildFile, in the target's Frameworks phase */
    ZZZZ = { isa = PBXBuildFile; productRef = YYYY /* NovaAIKit */; };
```

### Check

```bash
xcodebuild -resolvePackageDependencies -project "<App>.xcodeproj" | tail -3     # lists NovaAIKit 1.x
```

## Step 2: Create the app's single NovaAI instance

Create `<AppSource>/AI/AppAI.swift`. Use the **appID from the table below** exactly (it becomes the Keychain service):

```swift
import NovaAIKit

/// The app's one AI object (NovaAIKit). Settings persist in UserDefaults (no secrets); keys live in the Keychain
/// under com.jkoch.<appID>.<backend>.
@MainActor
enum AppAI {
    static let shared: NovaAI = {
        let ai = NovaAI(configuration: NovaAIConfiguration(
            appID: "<appID>",
            appName: "<App Name>"
            // keychainAccessGroup: "<TEAMID.group>",            // only if the app already uses one (step 0.2)
            // defaultSettings: NovaAISettings(backend: .ollama), // only if the app must not start on Auto
        ))
        AppAI.migrateLegacy(ai)        // step 3
        return ai
    }()
}
```

| App | appID | App | appID |
|---|---|---|---|
| MBox Explorer | `mboxexplorer` | Mail Summary | `mailsummary` |
| NMAPScanner | `nmapscanner` | OneOnOne | `oneonone` |
| AIStudio | `aistudio` | JiraSummary | `jirasummary` |
| Icon Creator | `iconcreator` | DotSync | `dotsync` |
| TopGUI | `topgui` | Stream Rotator | `streamrotator` |
| HomekitControl | `homekitcontrol` | RTSP Rotator | `rtsprotator` |
| ExcelExplorer | `excelexplorer` | NovaControl | `novacontrol` |
| Bastion | `bastion` | Nova-Desktop | `novadesktop` |
| URL-Analysis | `urlanalysis` | MboxChatCLI | `mboxchatcli` |
| News Summary | `newssummary` | DashboardScreensaver | `dashboardscreensaver` |
| RsyncGUI | `rsyncgui` | Lodestar | `lodestar` |
| MLX Code | `mlxcode` | CarTest | `cartest` |
| StuntDriver | `stuntdriver` | GTNW | `gtnw` |
| Blompie | `blompie` | BlompieTV | `blompietv` |

Special cases:

- **Settings not in UserDefaults** (CarTest: games DB). Implement `NovaAISettingsStorage` (`load()`/`save(_:)`)
  over the existing store and pass `storage:`. Settings contain no secrets.
- **CLI or other non-UI code** (MboxChatCLI, Lodestar): `AppAI.shared` still works. Mark the calling function
  `@MainActor` or `await` it. Code that must stay off the main actor can use `AppAI.shared.engine`, a `Sendable`
  snapshot: `try await engine.complete(request)`.
- **Several fixed LAN servers** (CarTest, StuntDriver): put them in
  `defaultSettings.extraOllamaEndpoints` (DNS names, never IPs) and set the primary with
  `defaultSettings.setURL(_:for: .ollama)`.
- **In-process MLX** (MLX Code): link `NovaAIKitMLX` and pass
  `localModel: NovaAIClosureModel(isAvailable: {…}, complete: { messages, temperature, maxTokens in … })`.

## Step 3: Migrate old settings and keys (once, at first launch)

Add this to `AppAI.swift`:

```swift
extension AppAI {
    static func migrateLegacy(_ ai: NovaAI) {
        // 3a. Old AIBackendManager UserDefaults: URLs, backend, Ollama model, on/off; a plaintext OpenAI key goes to
        //     the Keychain (the defaults entry is removed only after a verified write); obsolete secrets of the
        //     removed Google/Azure/AWS/IBM backends and the EthicalAIGuardian prompt log are deleted.
        ai.migrateFromLegacyAIBackendManager()

        // 3b. Old Keychain items → com.jkoch.<appID>.<backend>. Copy, verify, keep the old item unless it was
        //     this app's alone. One line per old item found in step 0:
        ai.migrateLegacyKey(service: "<old service>", account: "openAIAPIKey", to: .openAI, deleteLegacy: true)
        ai.migrateLegacyKey(service: "com.jkoch.aistudio.openrouter", account: "apiKey", to: .openRouter) // shared: keep

        // 3c. Delete the removed backends' secrets from the old service (deletes only; never reads them out).
        ai.keys.deleteObsoleteLegacyItems(service: "<old service>")
    }
}
```

Known old items:

| Old service | Old account | → backend | `deleteLegacy` |
|---|---|---|---|
| `com.jordankoch.<App>` (JiraSummary, DotSync, MBox Explorer, …) | `openAIAPIKey` | `.openAI` | `true` |
| `com.jordankoch.NewsSummary.AIBackend` | `openAIAPIKey` | `.openAI` | `true` |
| `com.jordankoch.MBoxExplorer` | `OpenWebUIEmbedding_APIKey` | `.openWebUI` (only if used for chat) | `false` |
| `com.jkoch.aistudio.openrouter` | `apiKey` | `.openRouter` | `false` (AIStudio still owns it) |
| `com.jordankoch.Blompie.openrouter` | `apiKey` | `.openRouter` | `true` |
| `com.jordankoch.GTNW` | `openAIAPIKey` | `.openAI` | `true` |
| UserDefaults `AIBackend_OpenAI_Key` / `OpenAIAPIKey` | n/a | `.openAI` | handled by 3a |
| already `com.jkoch.<appID>.openrouter/openai` (CarTest, StuntDriver, GTNW, BlompieTV) | `apiKey` | same | nothing to do |

Old UserDefaults keys and where `migrateFromLegacyAIBackendManager` puts them:

| Old key | New place |
|---|---|
| `AIBackend_Active`, `AIBackendManager_SelectedBackend`, `selectedAIBackend` (display names: "Ollama", "MLX Toolkit", "TinyLLM", "TinyChat", "OpenWebUI", "OpenAI", "Auto (Prefer Ollama)"; Google/Azure/AWS/IBM → Auto) | `settings.backend` |
| `AIBackend_OllamaURL`, `AIBackend_TinyLLMURL`, `AIBackend_TinyChatURL`, `AIBackend_OpenWebUIURL` (+ `AIBackendManager_*URL`) | `settings.urls[...]` |
| `AIBackend_OllamaModel`, `selectedOllamaModel`, `ollamaModel`, `ollamaLLMModel` | `settings.models["ollama"]` |
| `AIBackend_Enabled`, `AIBackendManager_AIEnabled`, `aiEnabled` | `settings.enabled` |
| `AIBackend_OpenAI_Key`, `OpenAIAPIKey` | Keychain `com.jkoch.<appID>.openai` |
| `AIBackend_GoogleCloud_Key`, `_Azure_*`, `_AWS_*`, `_IBM_*`, `AIGuardian_UsageLog`, `AIGuardian_PermanentBlock`, `AIBackend_UsageStats` | deleted |
| `AIBackend_ComfyUIURL`, `AIBackend_SwarmUIURL`, `AIBackend_Automatic1111URL` | untouched (image generation isn't part of NovaAIKit; the app keeps them if it still generates images) |

Keys the app used for anything other than these (app-specific prompts, history sizes and so on) stay the app's own.

## Step 4: Wire AI on/off, fallback and validation per feature

Every AI feature must still work when AI is off or down. For each feature listed in step 0.1:

| The feature… | Use | Fallback (required) | Validator |
|---|---|---|---|
| shows generated text (summary, explanation, naming) | `await AppAI.shared.text(request) { builtIn }` | Deterministic text: first sentences, a template, "Summary unavailable", the old non-AI path | default `NovaAI.nonEmpty`, plus length/`NovaAIText.plain`; for numbers use `NovaAIText.grounded(reply, in: source)` |
| extracts structure (tags, categories, JSON, lists) | `await AppAI.shared.structured(T.self, request, schema: schema, validate: clamp) { defaultT }` | Rule/keyword-based result, or empty | Clamp enums, ranges and counts; throw `NovaAIValidationError("why")` to reject |
| is a chat UI | `for try await d in AppAI.shared.stream(NovaAIRequest(messages: history))` in `do/catch` | `catch`: show `NovaAIError.errorDescription` in the transcript; the UI stays usable | none |
| changes app/game state (scores, moves, settings) | `await AppAI.shared.generate(request, validate: parseAndClamp, fallback: ruleBased)` | The rule-based or scripted engine | **Mandatory.** Reject anything outside the legal range |

Show where a value came from wherever the user sees it: `result.source.label` ("AI · Ollama (qwen3:8b)" /
"Built-in"), or `result.isAI` for a badge.

Requests:

```swift
NovaAIRequest(prompt: userText, system: systemPrompt, temperature: 0.3, maxTokens: 400)        // one-shot
NovaAIRequest(messages: [.system(s), .user(a), .assistant(b), .user(c)])                        // conversation
NovaAIRequest(prompt: p, format: .json)                                                         // any JSON
try NovaAIJSONSchema(name: "triage", json: "{…}")                                               // schema
```

## Step 5: Replace the app's AI client calls

| Old | New |
|---|---|
| `try await AIBackendManager.shared.generate(prompt: p, systemPrompt: s, temperature: t, maxTokens: n)` | `try await AppAI.shared.generate(prompt: p, systemPrompt: s, temperature: t, maxTokens: n)`, or better the never-throwing form from step 4 |
| `aiBackend.generate(…)` where `aiBackend` is a stored `AIBackendManager` | delete the property and call `AppAI.shared` |
| `manager.generateWithFallback(prompt:systemPrompt:)` | `AppAI.shared.text(NovaAIRequest(prompt: p, system: s)) { fallback }` |
| `manager.isEnabled` | `AppAI.shared.isEnabled` |
| `manager.anyBackendAvailable` / `isOllamaAvailable` … | `AppAI.shared.status.isReachable` / `status.reachability[.ollama] == true` (call `await AppAI.shared.refreshStatus()` first if no call has run yet) |
| `AIBackendManager.shared.activeBackend` (shown in UI) | `AppAI.shared.status.activeBackend?.displayName ?? "None"` |
| `AIBackendManager.shared.activeBackend = .ollama` | `AppAI.shared.settings.backend = .ollama` |
| `selectedOllamaModel` / `ollamaServerURL` | `AppAI.shared.settings.model(for: .ollama)` / `.url(for: .ollama)`; set with `setModel` / `setURL` |
| `refreshAllBackends()` / `checkBackendAvailability()` | `await AppAI.shared.refreshStatus()` |
| `ollamaModels` (model picker) | `await AppAI.shared.listModels(for: .ollama)` |
| `openAIAPIKey = x` / `saveToKeychain` | `AppAI.shared.setAPIKey(x, for: .openAI)` |
| Direct `URLSession` calls to `/api/chat`, `/api/generate`, `/v1/chat/completions` | `AppAI.shared.complete(_:)` / `stream(_:)` |
| `@ObservedObject var manager = AIBackendManager.shared` | `@ObservedObject var ai = AppAI.shared` |
| Code inside an `actor` or a background task | `await AppAI.shared.generate(…)` (hops to the main actor, network runs off it) or `let e = await AppAI.shared.engine; try await e.complete(req)` |

Embeddings, vector databases, speech, OCR and image generation are **not** chat AI. Leave them where they are. If
they read an old AI setting (an Ollama URL, for example), point them at
`AppAI.shared.settings.url(for: .ollama)`.

## Step 6: Drop in the settings and status views

```swift
import NovaAIKit

// Settings window / tab (replaces AIBackendSettingsView, AIBackendStatusMenu, AISettingsView, …)
NovaAISettingsView(ai: AppAI.shared, footer: "When AI is off, <App> uses <built-in behaviour>.")

// Toolbar, menu bar or header (replaces any "Active: <backend>" text)
NovaAIStatusIndicator(ai: AppAI.shared)                    // dot + label; click re-checks
NovaAIStatusIndicator(ai: AppAI.shared, showsLabel: false) // dot only
```

Menu-bar apps: put `NovaAIStatusIndicator` in the menu's header view, and put `NovaAISettingsView` in the Settings
scene or window. tvOS: both views work; MLX is hidden automatically.

## Step 7: Delete the old AI code

Delete these files (remove them from the project or target too: XcodeGen picks up deletions after
`xcodegen generate`; for pbxproj, remove the file reference and its build file):

- `AIBackendManager.swift`, `AIBackendManager+Enhanced.swift`, `AIBackendManager+Generation.swift`,
  `AIBackendManager+EthicalGuardian.swift`, `AIBackendManager+Balancer.swift`
- `AIBackendStatusMenu.swift`, `AIBackendSettingsView.swift`, `AIBackendSelectionView.swift`
- `EthicalAIGuardian.swift`, `AIProfiler.swift`
- `AICapabilities/*` (`UnifiedAICapabilities`, `AnalysisUnified`, `ImageGenerationUnified`, `SecurityUnified`,
  `VoiceUnified`), unless a file is genuinely used for non-chat work. Check with
  `grep -rn "<TypeName>" --include='*.swift' .` before deleting. Any code that reads `OPENAI_API_KEY` from the
  environment must go.
- The app's own chat clients and helpers: `OllamaClient.swift`, `OllamaService.swift` (chat parts), `LLMClient.swift`,
  `LLMBalancerManager.swift`, `LLMBackendType.swift`, `ModelRegistry.swift`, `OpenRouterProvider.swift`,
  `KeychainStore.swift` (if it only held AI keys), `LLMLoadBalancerSupport.swift`, the AI `Retry.swift` (keep it if
  non-AI code uses it).
- Copies at the repo root that are in no target (`./AIBackendManager*.swift` etc.). They're dead.

Then run:

```bash
grep -rnE "AIBackendManager|EthicalAIGuardian|AIBackendStatusMenu|OPENAI_API_KEY|AIBackend_OpenAI_Key" --include='*.swift' . \
  | grep -v "migrateFromLegacyAIBackendManager"       # must print nothing
```

## Step 8: Tests to add

Create `<AppTests>/AIKitAdoptionTests.swift`. NovaAIKit's own suite covers the backends, retries, Keychain and
transport. The app's tests cover **the app's contract**. Use an in-memory store and a stub session. Never use the
real Keychain or network:

```swift
import XCTest
import NovaAIKit
@testable import <AppModule>

final class AIKitAdoptionTests: XCTestCase {
    @MainActor
    func makeAI(_ s: NovaAISettings = NovaAISettings()) -> NovaAI {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RefuseAllProtocol.self]          // nothing reaches a server
        return NovaAI(configuration: NovaAIConfiguration(appID: "<appID>", appName: "<App Name>"),
                      storage: NovaAIMemoryStorage(s), keyStore: NovaAIMemoryKeyStore(),
                      session: URLSession(configuration: cfg), sleep: { _ in })
    }

    /// Feature 1+2: AI off → every AI feature still produces its built-in result.
    @MainActor func testEveryFeatureWorksWithAIOff() async { /* call each feature with makeAI(NovaAISettings(enabled: false)); assert non-empty fallback */ }
    /// Feature 2+7: every backend down → built-in result, no hang.
    @MainActor func testEveryFeatureFallsBackWhenOffline() async { /* RefuseAllProtocol fails every request */ }
    /// Feature 8: the validator rejects out-of-range / ungrounded output.
    func testValidatorRejectsNonsense() throws { /* call the app's validator closures directly */ }
    /// Feature 4: the app's Keychain service names.
    func testKeychainServiceNames() {
        let c = NovaAIConfiguration(appID: "<appID>", appName: "<App Name>")
        XCTAssertEqual(c.keychainService(for: .openRouter), "com.jkoch.<appID>.openrouter")
    }
    /// Step 3: legacy migration maps the old settings (use a throwaway UserDefaults suite).
    @MainActor func testLegacySettingsMigrate() { /* set AIBackend_Active = "Ollama" in a suite; migrateFromLegacyAIBackendManager(defaults:) */ }
    /// No old AI code left.
    func testNoLegacyAIClientInSources() throws { /* scan the app's sources for "AIBackendManager" / "OPENAI_API_KEY" */ }
}

final class RefuseAllProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
    override func stopLoading() {}
}
```

Update existing tests that referenced deleted types (the `AIBackend` enum count, `EthicalAIGuardianTests`,
source-reading Keychain tests). Rewrite each one against NovaAIKit types (`NovaAIBackend.allCases.count == 9`, the
service names above). Don't just delete the coverage. If the repo groups tests into the 7 categories (security,
performance, retry, unit, integration, functional, frame), put each new test in the matching file.

## Step 9: Build, test, document, release

1. Release build with **zero warnings**:
   `xcodebuild -scheme <Scheme> -configuration Release -derivedDataPath ./dd build 2>&1 | grep -c " warning:"` must print `0`.
2. Run the full test suite: `xcodebuild test -scheme <Scheme> -derivedDataPath ./dd`.
3. Launch the app once and check:
   - the status indicator turns green with local Ollama running, and orange with it stopped;
   - turning AI off leaves every feature working;
   - a key you enter shows up as "stored", never as text.
4. README: add an "AI" section listing the backends and the toggle, the fallback behaviour per feature, the keys in
   the Keychain (`com.jkoch.<appID>.*`) and the status indicator. Link to NovaAIKit. Remove claims about
   Google/Azure/AWS/IBM.
5. Bump the version the way the repo already does. Add a CHANGELOG line: "AI: migrated to NovaAIKit 1.0.0 (…)".
6. Release ("do the needful"): export to `/Volumes/Data/xcode/binaries/YYYYMMDD-<App>-vX.Y.Z/` and the NAS, make
   the DMG, install to /Applications, push.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `No such module 'NovaAIKit'` | The dependency was added to the wrong target, or `xcodegen generate` wasn't re-run. |
| Status shows "Nova Gateway … online" but replies are slow | The gateway runs Nova's agent (`/api/chat`). For raw completions, point `novagateway` at the fleet router: `http://nova-core.digitalnoise.net:37475`. |
| Empty replies from qwen3 / deepseek-r1 | `reasoning: true` was set, or `maxTokens` is too small. Leave `reasoning` false (the default). |
| `insecureTransport` | A key was about to be sent over http. Use the https URL; local OpenWebUI may use `http://localhost`. |
| Keychain prompt on every rebuild (signed app) | Set `keychainAccessGroup` to the app's group, as CarTest does. Ad hoc builds: click Always Allow once. |
| `ld: warning: building for macOS-12.0, but linking with dylib … XCTest … built for newer version 14.0` | The **test target's** deployment target is below 14. Set `MACOSX_DEPLOYMENT_TARGET = 14.0` on the test target only; the app can stay lower. |
| Swift 5 app: "call to main actor-isolated …" | Call `AppAI.shared` from `@MainActor` code or `await` it. |
