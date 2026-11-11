//
//  SecurityTests.swift — keys only in Keychain, only over https, never leaked; migration safety.
//

import XCTest
@testable import NovaAIKit

final class SecurityTests: StubbedTestCase {
    func testKeyNeverSentOverPlainHTTP() async {
        setKey("sk-secret-1", .openAI)
        StubURLProtocol.respond { _ in .openAI("x") }
        let engine = makeEngine(only(.openAI, url: "http://api.example.com/v1"))
        do {
            _ = try await engine.complete(NovaAIRequest(prompt: "hi"))
            XCTFail("must refuse")
        } catch {
            XCTAssertEqual(error as? NovaAIError, .insecureTransport("api.example.com"))
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "nothing may be sent")
    }

    func testCloudKeyRefusedEvenOnLoopbackHTTP() async {
        setKey("sk-secret-1", .openRouter)
        StubURLProtocol.respond { _ in .openAI("x") }
        let engine = makeEngine(only(.openRouter, url: "http://127.0.0.1:9999/v1"))
        await XCTAssertThrowsAsync(try await engine.complete(NovaAIRequest(prompt: "hi")))
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testOptionalKeyAllowedToLoopbackOnly() async throws {
        setKey("owui-key", .openWebUI)
        StubURLProtocol.respond { _ in .openAI("ok") }
        let local = makeEngine(only(.openWebUI, url: "http://localhost:8080"))
        _ = try await local.complete(NovaAIRequest(prompt: "hi"))
        XCTAssertEqual(StubURLProtocol.requests.last?.headers["Authorization"], "Bearer owui-key")

        StubURLProtocol.respond { _ in .openAI("ok") }
        let lan = makeEngine(only(.openWebUI, url: "http://192.168.1.20:8080"))
        await XCTAssertThrowsAsync(try await lan.complete(NovaAIRequest(prompt: "hi")))
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testMissingKeyMeansNothingSent() async {
        StubURLProtocol.respond { _ in .openAI("x") }
        let engine = makeEngine(only(.openRouter))
        do {
            _ = try await engine.complete(NovaAIRequest(prompt: "hi"))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? NovaAIError, .missingKey(.openRouter))
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testAutoSkipsKeyedBackendsWithoutKeys() {
        let engine = makeEngine()
        let backends = Set(engine.candidates().map(\.backend))
        XCTAssertFalse(backends.contains(.openRouter))
        XCTAssertFalse(backends.contains(.openAI))
    }

    func testLocalBackendsNeverGetAuthorization() async throws {
        setKey("sk-1", .openAI)
        setKey("sk-2", .openRouter)
        StubURLProtocol.respond { r in r.url.path.contains("api/chat") ? .ollama("ok") : .openAI("ok") }
        for b: NovaAIBackend in [.ollama, .mlx, .tinyLLM, .tinyChat, .novaGateway] {
            _ = try await makeEngine(only(b)).complete(NovaAIRequest(prompt: "hi"))
            XCTAssertNil(StubURLProtocol.requests.last?.headers["Authorization"], b.rawValue)
        }
    }

    func testOpenRouterHeadersAttributeThisApp() async throws {
        setKey("sk-or-test", .openRouter)
        StubURLProtocol.respond { _ in .openAI("ok") }
        _ = try await makeEngine(only(.openRouter)).complete(NovaAIRequest(prompt: "hi"))
        let h = StubURLProtocol.requests.last?.headers ?? [:]
        XCTAssertEqual(h["Authorization"], "Bearer sk-or-test")
        XCTAssertEqual(h["X-Title"], "NovaAIKit Tests")
        XCTAssertEqual(h["HTTP-Referer"], "https://github.com/kochj23/NovaAIKitTests")
        XCTAssertEqual(StubURLProtocol.requests.last?.url.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
    }

    @MainActor
    func testKeyNeverInSettingsStatusOrErrors() async {
        let ai = makeAI(only(.openAI))
        ai.setAPIKey("sk-very-secret", for: .openAI)
        StubURLProtocol.respond { _ in .status(401) }
        _ = try? await ai.complete(NovaAIRequest(prompt: "hi"))
        let blob = String(decoding: try! JSONEncoder().encode(ai.settings), as: UTF8.self)
        XCTAssertFalse(blob.contains("sk-very-secret"))
        XCTAssertFalse((ai.status.lastError ?? "").contains("sk-very-secret"))
        XCTAssertFalse(ai.status.label.contains("sk-very-secret"))
        XCTAssertFalse(String(describing: ai.status).contains("sk-very-secret"))
        XCTAssertEqual(storage.load()?.urls["openai"], nil)
    }

    @MainActor
    func testKeysGoToKeyStoreUnderAppService() {
        let ai = makeAI()
        XCTAssertTrue(ai.setAPIKey("  sk-abc \n", for: .openRouter))
        XCTAssertEqual(keys.read(service: "com.jkoch.novaaikit-tests.openrouter", account: "apiKey"), "sk-abc")
        XCTAssertTrue(ai.hasAPIKey(for: .openRouter))
        XCTAssertTrue(ai.setAPIKey(nil, for: .openRouter))
        XCTAssertFalse(ai.hasAPIKey(for: .openRouter))
        XCTAssertFalse(ai.setAPIKey("x", for: .ollama), "local backends take no key")
        XCTAssertEqual(keys.count, 0)
    }

    func testUnsafeURLsRejected() async {
        StubURLProtocol.respond { _ in .ollama("x") }
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "http://user:pw@host:1", "ftp://host"] {
            let engine = makeEngine(only(.tinyLLM, url: bad))
            await XCTAssertThrowsAsync(try await engine.complete(NovaAIRequest(prompt: "hi")), bad)
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: Migration

    func testLegacyKeychainMigrationCopiesThenOptionallyDeletes() {
        let k = NovaAIKeys(configuration: testConfig, store: keys)
        keys.write("sk-old", service: "com.jkoch.aistudio.openrouter", account: "apiKey")
        XCTAssertEqual(k.migrateLegacyKey(service: "com.jkoch.aistudio.openrouter", account: "apiKey", to: .openRouter), .migrated)
        XCTAssertEqual(k.key(for: .openRouter), "sk-old")
        XCTAssertEqual(keys.read(service: "com.jkoch.aistudio.openrouter", account: "apiKey"), "sk-old", "kept by default")
        XCTAssertEqual(k.migrateLegacyKey(service: "com.jkoch.aistudio.openrouter", account: "apiKey", to: .openRouter), .alreadyPresent)

        keys.write("sk-gtnw", service: "com.jordankoch.GTNW", account: "openAIAPIKey")
        XCTAssertEqual(k.migrateLegacyKey(service: "com.jordankoch.GTNW", account: "openAIAPIKey", to: .openAI, deleteLegacy: true), .migrated)
        XCTAssertNil(keys.read(service: "com.jordankoch.GTNW", account: "openAIAPIKey"))
        XCTAssertEqual(k.migrateLegacyKey(service: "nothing.here", account: "x", to: .openWebUI), .nothingToMigrate)
    }

    func testFailedMigrationWriteDeletesNothing() {
        let k = NovaAIKeys(configuration: testConfig, store: keys)
        keys.write("sk-old", service: "legacy", account: "a")
        keys.failWrites = true
        XCTAssertEqual(k.migrateLegacyKey(service: "legacy", account: "a", to: .openAI, deleteLegacy: true), .writeFailed)
        keys.failWrites = false
        XCTAssertEqual(keys.read(service: "legacy", account: "a"), "sk-old")
        XCTAssertNil(k.key(for: .openAI))
    }

    func testObsoleteLegacyKeychainItemsDeleted() {
        let k = NovaAIKeys(configuration: testConfig, store: keys)
        keys.write("g", service: "com.jordankoch.NewsSummary.AIBackend", account: "googleCloudAPIKey")
        keys.write("a", service: "com.jordankoch.NewsSummary.AIBackend", account: "awsSecretKey")
        keys.write("o", service: "com.jordankoch.NewsSummary.AIBackend", account: "openAIAPIKey")
        XCTAssertEqual(Set(k.deleteObsoleteLegacyItems(service: "com.jordankoch.NewsSummary.AIBackend")), ["googleCloudAPIKey", "awsSecretKey"])
        XCTAssertEqual(keys.read(service: "com.jordankoch.NewsSummary.AIBackend", account: "openAIAPIKey"), "o", "OpenAI untouched")
    }

    func testMigrationFromSeparateLegacyStore() {
        let legacy = NovaAIMemoryKeyStore(["legacy\u{1}apiKey": "sk-x"])
        let k = NovaAIKeys(configuration: testConfig, store: keys)
        XCTAssertEqual(k.migrateLegacyKey(service: "legacy", account: "apiKey", to: .openAI, deleteLegacy: true, legacyStore: legacy), .migrated)
        XCTAssertEqual(k.key(for: .openAI), "sk-x")
        XCTAssertEqual(legacy.count, 0)
    }

    func testPlaintextDefaultsKeyMovedToKeychain() {
        let suite = "NovaAIKitTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let k = NovaAIKeys(configuration: testConfig, store: keys)
        d.set("sk-plain", forKey: "AIBackend_OpenAI_Key")
        keys.failWrites = true
        XCTAssertEqual(k.migrateLegacyDefaultsKey("AIBackend_OpenAI_Key", defaults: d, to: .openAI), .writeFailed)
        XCTAssertEqual(d.string(forKey: "AIBackend_OpenAI_Key"), "sk-plain", "kept until the write succeeds")
        keys.failWrites = false
        XCTAssertEqual(k.migrateLegacyDefaultsKey("AIBackend_OpenAI_Key", defaults: d, to: .openAI), .migrated)
        XCTAssertNil(d.object(forKey: "AIBackend_OpenAI_Key"))
        XCTAssertEqual(k.key(for: .openAI), "sk-plain")
        d.set("sk-other", forKey: "AIBackend_OpenAI_Key")
        XCTAssertEqual(k.migrateLegacyDefaultsKey("AIBackend_OpenAI_Key", defaults: d, to: .openAI), .alreadyPresent)
        XCTAssertNil(d.object(forKey: "AIBackend_OpenAI_Key"), "plaintext copy removed even when the Keychain had one")
        XCTAssertEqual(k.key(for: .openAI), "sk-plain", "existing key not overwritten")
        d.set("", forKey: "AIBackend_OpenAI_Key")
        XCTAssertEqual(k.migrateLegacyDefaultsKey("AIBackend_OpenAI_Key", defaults: d, to: .openAI), .nothingToMigrate)
        XCTAssertNil(d.object(forKey: "AIBackend_OpenAI_Key"))
    }

    @MainActor
    func testObsoleteSecretsAndPromptLogPurged() {
        let suite = "NovaAIKitTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        d.set("aws-secret", forKey: "AIBackend_AWS_SecretKey")
        d.set(["prompt text"], forKey: "AIGuardian_UsageLog")
        d.set("sk-plain", forKey: "AIBackend_OpenAI_Key")
        d.set("Ollama", forKey: "AIBackend_Active")
        let ai = makeAI(NovaAISettings())
        let r = ai.migrateFromLegacyAIBackendManager(defaults: d)
        XCTAssertEqual(Set(r.removedKeys), ["AIBackend_AWS_SecretKey", "AIGuardian_UsageLog"])
        XCTAssertEqual(r.keys["AIBackend_OpenAI_Key"], .migrated)
        XCTAssertTrue(r.settingsImported)
        XCTAssertNil(d.object(forKey: "AIBackend_AWS_SecretKey"))
        XCTAssertNil(d.object(forKey: "AIBackend_OpenAI_Key"))
        XCTAssertEqual(ai.settings.backend, .ollama)
    }

    /// The real Keychain, under a throwaway service; cleaned up. Skips where no keychain is available.
    func testRealKeychainRoundTrip() throws {
        let kc = NovaAIKeychain()
        let service = "com.jkoch.novaaikit-tests.\(UUID().uuidString)"
        guard kc.write("v1", service: service, account: "apiKey") else { throw XCTSkip("Keychain unavailable here") }
        defer { kc.delete(service: service, account: "apiKey") }
        XCTAssertEqual(kc.read(service: service, account: "apiKey"), "v1")
        XCTAssertTrue(kc.write("v2", service: service, account: "apiKey"))
        XCTAssertEqual(kc.read(service: service, account: "apiKey"), "v2")
        XCTAssertTrue(kc.write("", service: service, account: "apiKey"), "empty deletes")
        XCTAssertNil(kc.read(service: service, account: "apiKey"))
        XCTAssertTrue(kc.delete(service: service, account: "apiKey"), "deleting a missing item is fine")
    }

    func testNoSecretsInSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: src, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        let patterns = [#"sk-[A-Za-z0-9]{20,}"#, #"sk-or-v1-[a-f0-9]{20,}"#, #"AKIA[0-9A-Z]{16}"#, #"AIza[0-9A-Za-z_-]{30,}"#, #"xox[bp]-"#]
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for p in patterns { XCTAssertNil(text.range(of: p, options: .regularExpression), "\(f.lastPathComponent) matches \(p)") }
            XCTAssertFalse(text.contains("ProcessInfo.processInfo.environment"), "keys never from the environment: \(f.lastPathComponent)")
            if f.lastPathComponent != "NovaAISettings.swift" && f.lastPathComponent != "NovaAIKeychain.swift" && f.lastPathComponent != "NovaAI.swift" {
                XCTAssertFalse(text.contains("UserDefaults"), "no UserDefaults outside settings/migration: \(f.lastPathComponent)")
            }
        }
    }
}

func XCTAssertThrowsAsync<T>(_ body: @autoclosure () async throws -> T, _ message: String = "",
                             isolation: isolated (any Actor)? = #isolation,
                             file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await body()
        XCTFail("expected an error \(message)", file: file, line: line)
    } catch {}
}
