//
//  FunctionalTests.swift — the app-facing contract end to end over stubbed HTTP: toggle, fallback, validation,
//  structured output, streaming, failover, model lists, gateway, legacy drop-in, local MLX engine.
//

import XCTest
@testable import NovaAIKit
import NovaAIKitMLX

final class FunctionalTests: StubbedTestCase {
    // MARK: Toggle + fallback

    @MainActor
    func testAIOffSendsNothingAndUsesFallback() async {
        StubURLProtocol.respond { _ in .ollama("AI") }
        let ai = makeAI(NovaAISettings(enabled: false))
        let r = await ai.text(NovaAIRequest(prompt: "x")) { "scripted" }
        XCTAssertEqual(r.value, "scripted")
        XCTAssertEqual(r.source, .fallback(.disabled))
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        await XCTAssertThrowsAsync(try await ai.generate(prompt: "x"))
        XCTAssertEqual(ai.status.state, .off)
    }

    @MainActor
    func testToggleIsPersisted() {
        let ai = makeAI()
        ai.isEnabled = false
        XCTAssertEqual(storage.load()?.enabled, false)
        let again = NovaAI(configuration: testConfig, storage: storage, keyStore: keys, session: StubURLProtocol.session())
        XCTAssertFalse(again.isEnabled)
    }

    @MainActor
    func testUnreachableUsesFallbackWithReason() async {
        StubURLProtocol.respond { _ in .fail(.cannotConnectToHost) }
        let ai = makeAI(only(.ollama))
        let r = await ai.text(NovaAIRequest(prompt: "x")) { "built-in" }
        XCTAssertEqual(r.value, "built-in")
        guard case .fallback(.unavailable(let why)) = r.source else { return XCTFail() }
        XCTAssertEqual(why, "connection refused")
        XCTAssertEqual(ai.status.state, .offline)
        XCTAssertEqual(ai.status.lastSource, r.source)
    }

    @MainActor
    func testValidatorRejectsThenRetriesWithComplaint() async {
        let n = NovaAICounter()
        StubURLProtocol.respond { _ in n.increment(); return .ollama(n.value == 1 ? "150" : "42") }
        let ai = makeAI(only(.ollama))
        let r = await ai.generate(NovaAIRequest(prompt: "pick 1-100"), validate: { s -> Int in
            guard let v = Int(s), (1...100).contains(v) else { throw NovaAIValidationError("must be 1-100") }
            return v
        }, fallback: { 50 })
        XCTAssertEqual(r.value, 42)
        XCTAssertTrue(r.isAI)
        let retry = StubURLProtocol.requests[1].json["messages"] as? [[String: String]] ?? []
        XCTAssertEqual(retry.suffix(2).first?["content"], "150")
        XCTAssertTrue(retry.last?["content"]?.contains("must be 1-100") == true)
    }

    @MainActor
    func testValidatorRejectsTwiceFallsBack() async {
        StubURLProtocol.respond { _ in .ollama("nonsense") }
        let ai = makeAI(only(.ollama))
        let r = await ai.generate(NovaAIRequest(prompt: "x"), validate: { s -> Int in
            guard let v = Int(s) else { throw NovaAIValidationError("not a number") }
            return v
        }, fallback: { 7 })
        XCTAssertEqual(r.value, 7)
        XCTAssertEqual(r.source, .fallback(.validationFailed("not a number")))
        XCTAssertEqual(StubURLProtocol.requests.count, 2, "exactly one retry")
    }

    @MainActor
    func testValidatorCanClamp() async {
        StubURLProtocol.respond { _ in .ollama("999") }
        let ai = makeAI(only(.ollama))
        let r = await ai.generate(NovaAIRequest(prompt: "x"), validate: { min(Int($0) ?? 0, 100) }, fallback: { 0 })
        XCTAssertEqual(r.value, 100)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    // MARK: Structured output

    struct Triage: Codable, Equatable, Sendable { var category: String; var priority: Int }

    @MainActor
    func testStructuredWithSchemaOllama() async throws {
        StubURLProtocol.respond { _ in .ollama("```json\n{\"category\":\"bill\",\"priority\":2}\n```") }
        let ai = makeAI(only(.ollama))
        let schema = try NovaAIJSONSchema(name: "triage", json: #"{"type":"object","required":["category","priority"],"properties":{"category":{"type":"string"},"priority":{"type":"integer"}}}"#)
        let r = await ai.structured(Triage.self, NovaAIRequest(prompt: "triage this"), schema: schema) { Triage(category: "other", priority: 3) }
        XCTAssertEqual(r.value, Triage(category: "bill", priority: 2))
        XCTAssertTrue(r.isAI)
        let format = StubURLProtocol.requests[0].json["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "object")
    }

    @MainActor
    func testStructuredWrongShapeRetriesThenFallback() async {
        StubURLProtocol.respond { _ in .openAI(#"{"cat":"x"}"#) }
        let ai = makeAI(only(.tinyLLM))
        let r = await ai.structured(Triage.self, NovaAIRequest(prompt: "x")) { Triage(category: "other", priority: 3) }
        XCTAssertEqual(r.value.category, "other")
        guard case .fallback(.validationFailed(let why)) = r.source else { return XCTFail() }
        XCTAssertTrue(why.contains("category"))
    }

    @MainActor
    func testStructuredValidatorClamps() async {
        StubURLProtocol.respond { _ in .ollama(#"{"category":"bill","priority":99}"#) }
        let ai = makeAI(only(.ollama))
        let r = await ai.structured(Triage.self, NovaAIRequest(prompt: "x"),
                                    validate: { t in var t = t; t.priority = min(max(t.priority, 1), 5); return t },
                                    fallback: { Triage(category: "other", priority: 3) })
        XCTAssertEqual(r.value.priority, 5)
    }

    // MARK: Failover + routing

    func testAutoFailsOverInFixedOrder() async throws {
        setKey("sk-or", .openRouter)
        StubURLProtocol.respond { r in r.url.host == "openrouter.ai" ? .openAI("frontier") : .fail(.cannotConnectToHost) }
        let r = try await makeEngine().complete(NovaAIRequest(prompt: "x"))
        XCTAssertEqual(r.backend, .openRouter)
        XCTAssertEqual(r.text, "frontier")
        let order = StubURLProtocol.requests.map { $0.url.absoluteString }
        XCTAssertEqual(order, [
            "http://localhost:11434/api/chat", "http://localhost:8081/v1/chat/completions",
            "http://localhost:8000/api/chat/stream", "http://localhost:8000/v1/chat/completions",
            "http://localhost:8080/api/chat/completions", "http://127.0.0.1:18792/v1/chat/completions",
            "https://openrouter.ai/api/v1/chat/completions",
        ])
    }

    func testExtraOllamaEndpointsTriedInOrder() async throws {
        var s = only(.ollama, url: "http://nova-core8.digitalnoise.net:11434")
        s.extraOllamaEndpoints = [NovaAIEndpoint(url: "http://nova-core.digitalnoise.net:37475", model: "fast")]
        StubURLProtocol.respond { r in r.url.port == 37475 ? .ollama("router") : .fail(.cannotConnectToHost) }
        let r = try await makeEngine(s).complete(NovaAIRequest(prompt: "x"))
        XCTAssertEqual(r.text, "router")
        XCTAssertEqual(r.model, "fast")
        XCTAssertEqual(StubURLProtocol.requests.last?.json["model"] as? String, "fast")
    }

    func testRequestOverridesBackendAndModel() async throws {
        StubURLProtocol.respond { _ in .openAI("ok") }
        var req = NovaAIRequest(prompt: "x")
        req.backend = .tinyLLM
        req.model = "special"
        let r = try await makeEngine().complete(req)
        XCTAssertEqual(r.backend, .tinyLLM)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(StubURLProtocol.requests[0].json["model"] as? String, "special")
    }

    func testEmptyReplyFailsOver() async throws {
        StubURLProtocol.respond { r in r.url.port == 11434 ? .ollama("<think>only thoughts</think>") : .openAI("real") }
        let r = try await makeEngine().complete(NovaAIRequest(prompt: "x"))
        XCTAssertEqual(r.backend, .mlx)
    }

    func testNovaGatewayFallsBackToNativeAPI() async throws {
        StubURLProtocol.respond { r in
            r.url.path == "/v1/chat/completions" ? .status(404) : .json(#"{"ok":true,"response":"Nova here","trace_id":"t"}"#)
        }
        let engine = makeEngine(only(.novaGateway))
        let r = try await engine.complete(NovaAIRequest(prompt: "hello", system: "be brief"))
        XCTAssertEqual(r.text, "Nova here")
        XCTAssertEqual(StubURLProtocol.requests.last?.url.path, "/api/chat")
        XCTAssertEqual(StubURLProtocol.requests.last?.json["person"] as? String, "service")
        // Remembered: the next call goes straight to /api/chat.
        _ = try await engine.complete(NovaAIRequest(prompt: "again"))
        XCTAssertEqual(StubURLProtocol.requests.suffix(1).map(\.url.path), ["/api/chat"])
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
    }

    func testNovaGatewayOpenAICompatibleFleetEndpoint() async throws {
        StubURLProtocol.respond { _ in .openAI("fleet") }
        let r = try await makeEngine(only(.novaGateway, url: "http://nova-core.digitalnoise.net:37475")).complete(NovaAIRequest(prompt: "x"))
        XCTAssertEqual(r.text, "fleet")
        XCTAssertEqual(StubURLProtocol.requests[0].url.absoluteString, "http://nova-core.digitalnoise.net:37475/v1/chat/completions")
    }

    // MARK: Drop-in API

    @MainActor
    func testLegacyGenerateSignature() async throws {
        StubURLProtocol.respond { _ in .ollama("summary") }
        let ai = makeAI(only(.ollama))
        let s = try await ai.generate(prompt: "Summarize", systemPrompt: "You summarize.", temperature: 0.3, maxTokens: 200)
        XCTAssertEqual(s, "summary")
        let body = StubURLProtocol.requests[0].json
        XCTAssertEqual((body["options"] as? [String: Any])?["num_predict"] as? Int, 200)
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "You summarize.")
    }

    @MainActor
    func testMultiTurnChatSendsHistory() async throws {
        StubURLProtocol.respond { _ in .openAI("third") }
        let ai = makeAI(only(.mlx))
        _ = try await ai.chat([.system("s"), .user("one"), .assistant("two"), .user("three?")])
        let msgs = StubURLProtocol.requests[0].json["messages"] as? [[String: String]] ?? []
        XCTAssertEqual(msgs.map { $0["role"] ?? "" }, ["system", "user", "assistant", "user"])
    }

    // MARK: Streaming

    @MainActor
    func testStreamOllamaNDJSONStripsThinking() async throws {
        StubURLProtocol.respond { _ in
            .lines([#"{"message":{"content":"<think>hm"},"done":false}"#, #"{"message":{"content":"</think>Hel"},"done":false}"#,
                    #"{"message":{"content":"lo"},"done":false}"#, #"{"message":{"content":""},"done":true}"#])
        }
        let ai = makeAI(only(.ollama))
        var out = ""
        for try await d in ai.stream(NovaAIRequest(prompt: "x")) { out += d }
        XCTAssertEqual(out, "Hello")
        XCTAssertEqual(StubURLProtocol.requests[0].json["stream"] as? Bool, true)
        XCTAssertEqual(ai.status.state, .online)
        XCTAssertEqual(ai.status.activeBackend, .ollama)
    }

    func testStreamOpenAISSEAndFinishedEvent() async throws {
        setKey("sk", .openAI)
        StubURLProtocol.respond { _ in
            .lines(["data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}", "data: {\"choices\":[{\"delta\":{\"content\":\"A\"}}]}",
                    ": ping", "data: {\"choices\":[{\"delta\":{\"content\":\"B\"}}]}", "data: [DONE]"])
        }
        var deltas: [String] = []
        var finished: NovaAIResponse?
        for try await e in makeEngine(only(.openAI)).stream(NovaAIRequest(prompt: "x")) {
            switch e {
            case .delta(let d): deltas.append(d)
            case .finished(let r): finished = r
            }
        }
        XCTAssertEqual(deltas.joined(), "AB")
        XCTAssertEqual(finished?.text, "AB")
        XCTAssertEqual(finished?.backend, .openAI)
    }

    func testStreamFailsOverBeforeFirstByte() async throws {
        StubURLProtocol.respond { r in r.url.port == 11434 ? .fail(.cannotConnectToHost) : .lines(["data: {\"choices\":[{\"delta\":{\"content\":\"mlx\"}}]}", "data: [DONE]"]) }
        var out = ""
        for try await e in makeEngine().stream(NovaAIRequest(prompt: "x")) { if case .delta(let d) = e { out += d } }
        XCTAssertEqual(out, "mlx")
    }

    @MainActor
    func testStreamWhenDisabledThrows() async {
        let ai = makeAI(NovaAISettings(enabled: false))
        do {
            for try await _ in ai.stream(NovaAIRequest(prompt: "x")) {}
            XCTFail()
        } catch { XCTAssertEqual(error as? NovaAIError, .disabled) }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: Models + probes

    @MainActor
    func testListModelsFromOllamaAndOpenAIShapes() async {
        setKey("sk", .openRouter)
        StubURLProtocol.respond { r in
            r.url.path == "/api/tags" ? .json(#"{"models":[{"name":"qwen3:8b"},{"name":"llama3.2:3b"}]}"#)
                                      : .json(#"{"data":[{"id":"anthropic/claude-sonnet-4.5"},{"id":"openai/gpt-4o"}]}"#)
        }
        let ai = makeAI()
        let ollama = await ai.listModels(for: .ollama)
        XCTAssertEqual(ollama, ["llama3.2:3b", "qwen3:8b"])
        let or = await ai.listModels(for: .openRouter)
        XCTAssertEqual(or, ["anthropic/claude-sonnet-4.5", "openai/gpt-4o"])
        XCTAssertEqual(StubURLProtocol.requests.last?.headers["Authorization"], "Bearer sk")
    }

    @MainActor
    func testListModelsFallsBackToKnownList() async {
        StubURLProtocol.respond { _ in .status(404) }
        let ai = makeAI()
        let gw = await ai.listModels(for: .novaGateway)
        XCTAssertEqual(gw, NovaAIBackend.novaGateway.fallbackModels)
        let noKey = await ai.listModels(for: .openAI)
        XCTAssertEqual(noKey, NovaAIBackend.openAI.fallbackModels)
    }

    func testProbeRules() async {
        StubURLProtocol.respond { r in r.url.port == 11434 ? .status(404) : .status(401) }
        let engine = makeEngine()
        let ollama = await engine.probe(.ollama)
        XCTAssertTrue(ollama.reachable, "a local server answering 404 is up")
        let noKey = await engine.probe(.openAI)
        XCTAssertFalse(noKey.reachable)
        XCTAssertEqual(noKey.detail, "no API key")
        setKey("bad", .openAI)
        let badKey = await engine.probe(.openAI)
        XCTAssertFalse(badKey.reachable, "keyed backends need 2xx")
        XCTAssertEqual(badKey.detail, "HTTP 401")
    }

    @MainActor
    func testRefreshStatusPicksFirstReachableInOrder() async {
        StubURLProtocol.respond { r in r.url.port == 8000 ? .json("{}") : .fail(.cannotConnectToHost) }
        let ai = makeAI()
        await ai.refreshStatus()
        XCTAssertEqual(ai.status.state, .online)
        XCTAssertEqual(ai.status.activeBackend, .tinyChat)
        XCTAssertEqual(ai.status.reachability[.ollama], false)
        XCTAssertEqual(ai.status.host, "localhost")
    }

    @MainActor
    func testTestConnectionSingleBackend() async {
        StubURLProtocol.respond { _ in .json(#"{"models":[]}"#) }
        let ai = makeAI(only(.ollama))
        let p = await ai.testConnection()
        XCTAssertTrue(p.reachable)
        XCTAssertEqual(p.detail, "HTTP 200")
    }

    // MARK: Legacy settings + local MLX

    @MainActor
    func testLegacySettingsImportedOnce() {
        let suite = "NovaAIKitTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        d.set("http://nova-core8:11434", forKey: "AIBackend_OllamaURL")
        d.set("TinyLLM", forKey: "AIBackend_Active")
        d.set("llama3.2:3b", forKey: "AIBackend_OllamaModel")
        let ai = makeAI()
        XCTAssertTrue(ai.migrateLegacySettings(from: d))
        XCTAssertEqual(ai.settings.backend, .tinyLLM)
        XCTAssertEqual(ai.settings.url(for: .ollama), "http://nova-core8:11434")
        XCTAssertEqual(ai.settings.model(for: .ollama), "llama3.2:3b")
        XCTAssertEqual(storage.load()?.backend, .tinyLLM, "persisted")
        ai.settings.backend = .ollama
        XCTAssertFalse(ai.migrateLegacySettings(from: d), "once only")
        XCTAssertEqual(ai.settings.backend, .ollama)
    }

    @MainActor
    func testLocalMLXModelPlugsIn() async throws {
        let local = NovaAIClosureModel { msgs, _, _ in "local: \(msgs.last?.content ?? "")" }
        let ai = makeAI(only(.mlx), localModel: local)
        let s = try await ai.generate(prompt: "hi")
        XCTAssertEqual(s, "local: hi")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        let p = await ai.testConnection(.mlx)
        XCTAssertTrue(p.reachable)
        let models = await ai.listModels(for: .mlx)
        XCTAssertEqual(models, [NovaAIBackend.mlx.defaultModel])
    }

    func testMLXServerCommandLine() {
        #if os(macOS)
        let s = NovaAIMLXServer(model: "mlx-community/Qwen3-8B-4bit", port: 8099)
        XCTAssertEqual(s.arguments, ["python3", "-m", "mlx_lm.server", "--model", "mlx-community/Qwen3-8B-4bit", "--host", "127.0.0.1", "--port", "8099"])
        XCTAssertEqual(s.baseURL, "http://127.0.0.1:8099")
        XCTAssertTrue(NovaAIMLXServer.isValidModel("mlx-community/Qwen3-8B-4bit"))
        XCTAssertFalse(NovaAIMLXServer.isValidModel("--evil"))
        XCTAssertFalse(NovaAIMLXServer.isValidModel("a; rm -rf /"))
        XCTAssertThrowsError(try NovaAIMLXServer(model: "a b").start())
        XCTAssertFalse(s.isRunning)
        #endif
    }
}
