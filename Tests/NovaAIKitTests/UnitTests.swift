//
//  UnitTests.swift — pure logic: ids, settings, text helpers, wire formats, retry policy.
//

import XCTest
@testable import NovaAIKit

final class UnitTests: XCTestCase {
    // MARK: Backends

    func testCanonicalRawValuesAreStable() {
        XCTAssertEqual(NovaAIBackend.allCases.map(\.rawValue),
                       ["auto", "ollama", "mlx", "tinyllm", "tinychat", "openwebui", "novagateway", "openrouter", "openai",
                        "anthropic", "gemini", "xai", "mistral", "deepseek", "meta"])
    }

    func testAutoOrderIsFixedLocalFirst() {
        XCTAssertEqual(NovaAIBackend.autoOrder, [.ollama, .mlx, .tinyChat, .tinyLLM, .openWebUI, .novaGateway, .openRouter, .openAI,
                                                 .anthropic, .gemini, .xAI, .mistral, .deepSeek, .meta])
        let firstCloud = NovaAIBackend.autoOrder.firstIndex(where: \.requiresKey)!
        XCTAssertTrue(NovaAIBackend.autoOrder[firstCloud...].allSatisfy(\.requiresKey), "every cloud backend comes after the local ones")
        XCTAssertEqual(NovaAIBackend.selectable.first, .auto)
        XCTAssertFalse(NovaAIBackend.autoOrder.contains(.auto))
    }

    func testNoRemovedCloudBackends() {
        let names = NovaAIBackend.allCases.map { $0.rawValue + $0.displayName }.joined().lowercased()
        for gone in ["vertex", "azure", "aws", "watson"] { XCTAssertFalse(names.contains(gone), gone) }
    }

    func testKeyRequirements() {
        let cloud: [NovaAIBackend] = [.openRouter, .openAI, .anthropic, .gemini, .xAI, .mistral, .deepSeek, .meta]
        XCTAssertEqual(NovaAIBackend.allCases.filter(\.requiresKey), cloud)
        XCTAssertEqual(NovaAIBackend.allCases.filter(\.acceptsKey), [.openWebUI] + cloud)
    }

    func testDefaultURLsLocalhostExceptCloud() {
        for b in NovaAIBackend.autoOrder {
            let host = URL(string: b.defaultURL)?.host ?? ""
            if b.requiresKey { XCTAssertTrue(b.defaultURL.hasPrefix("https://"), b.rawValue) }
            else { XCTAssertTrue(host == "localhost" || host == "127.0.0.1", "\(b.rawValue) \(host)") }
        }
    }

    func testEveryBackendHasPathsAndModel() {
        for b in NovaAIBackend.autoOrder {
            XCTAssertTrue(b.chatPath.hasPrefix("/"), b.rawValue)
            XCTAssertTrue(b.modelsPath.hasPrefix("/"), b.rawValue)
            XCTAssertFalse(b.defaultModel.isEmpty, b.rawValue)
            XCTAssertFalse(b.fallbackModels.isEmpty, b.rawValue)
            XCTAssertFalse(b.summary.isEmpty)
            XCTAssertFalse(b.symbolName.isEmpty)
        }
    }

    func testLegacyNamesMap() {
        XCTAssertEqual(NovaAIBackend(legacyName: "Ollama"), .ollama)
        XCTAssertEqual(NovaAIBackend(legacyName: "MLX Toolkit"), .mlx)
        XCTAssertEqual(NovaAIBackend(legacyName: "TinyLLM"), .tinyLLM)
        XCTAssertEqual(NovaAIBackend(legacyName: "TinyChat"), .tinyChat)
        XCTAssertEqual(NovaAIBackend(legacyName: "OpenWebUI"), .openWebUI)
        XCTAssertEqual(NovaAIBackend(legacyName: "OpenAI"), .openAI)
        XCTAssertEqual(NovaAIBackend(legacyName: "Auto (Prefer Ollama)"), .auto)
        XCTAssertEqual(NovaAIBackend(legacyName: "IBM Watson"), .auto)
        XCTAssertEqual(NovaAIBackend(legacyName: "Google Cloud AI"), .auto)
        XCTAssertEqual(NovaAIBackend(legacyName: "openrouter"), .openRouter)
        XCTAssertEqual(NovaAIBackend(legacyName: "Nova Gateway"), .novaGateway)
        XCTAssertNil(NovaAIBackend(legacyName: "bogus"))
    }

    // MARK: Settings

    func testSettingsDefaults() {
        let s = NovaAISettings()
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.backend, .auto)
        XCTAssertEqual(s.url(for: .ollama), "http://localhost:11434")
        XCTAssertEqual(s.model(for: .ollama), "qwen3:8b")
    }

    func testSettingsSettersClearDefaultsAndTrim() {
        var s = NovaAISettings()
        s.setURL("http://nova-core8:11434/// ", for: .ollama)
        XCTAssertEqual(s.url(for: .ollama), "http://nova-core8:11434")
        s.setURL(NovaAIBackend.ollama.defaultURL, for: .ollama)
        XCTAssertNil(s.urls["ollama"])
        s.setModel("llama3.2:3b", for: .ollama)
        XCTAssertEqual(s.model(for: .ollama), "llama3.2:3b")
        s.setModel("", for: .ollama)
        XCTAssertEqual(s.model(for: .ollama), "qwen3:8b")
        s.setURL(String(repeating: "x", count: 1000), for: .tinyLLM)
        XCTAssertEqual(s.urls["tinyllm"]?.count, NovaAISettings.maxURLLength)
    }

    func testSettingsRoundTrip() throws {
        var s = NovaAISettings(enabled: false, backend: .openRouter, timeout: 45)
        s.setModel("openai/gpt-4o", for: .openRouter)
        s.extraOllamaEndpoints = [NovaAIEndpoint(url: "http://nova-core.digitalnoise.net:37475", model: "fast")]
        let back = try JSONDecoder().decode(NovaAISettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testSettingsDecodeIsTolerant() throws {
        let json = #"{"enabled":"yes","backend":"googleCloud","urls":{"ollama":"http://x:1","auto":"nope","zzz":"q"},"timeout":99999}"#
        let s = try JSONDecoder().decode(NovaAISettings.self, from: Data(json.utf8))
        XCTAssertTrue(s.enabled)                   // bad type → default
        XCTAssertEqual(s.backend, .auto)           // unknown → auto
        XCTAssertEqual(s.urls, ["ollama": "http://x:1"])
        XCTAssertEqual(s.timeout, 600)             // clamped
        let empty = try JSONDecoder().decode(NovaAISettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, NovaAISettings())
    }

    func testConfigurationIDsAndServices() {
        let c = NovaAIConfiguration(appID: "Mail Summary!", appName: "Mail Summary")
        XCTAssertEqual(c.appID, "mailsummary")
        XCTAssertEqual(c.keychainService(for: .openRouter), "com.jkoch.mailsummary.openrouter")
        XCTAssertEqual(c.keychainService(for: .openAI), "com.jkoch.mailsummary.openai")
        XCTAssertEqual(c.appURL, "https://github.com/kochj23/MailSummary")
        XCTAssertEqual(NovaAIConfiguration.keychainAccount, "apiKey")
        XCTAssertEqual(NovaAIConfiguration.normalizedID("***"), "app")
    }

    func testUserDefaultsStorageRoundTrip() {
        let suite = "NovaAIKitTests.\(UUID().uuidString)"
        let store = NovaAIUserDefaultsStorage(suiteName: suite)
        XCTAssertNil(store.load())
        let s = NovaAISettings(enabled: false, backend: .ollama)
        store.save(s)
        XCTAssertEqual(store.load(), s)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    // MARK: Text

    func testCleanStripsThinking() {
        XCTAssertEqual(NovaAIText.clean("<think>plan</think>\n Hello "), "Hello")
        XCTAssertEqual(NovaAIText.clean("reasoning…</think>Answer"), "Answer")
        XCTAssertEqual(NovaAIText.clean("A<think>x</think>B<think>y</think>C"), "ABC")
        XCTAssertNil(NovaAIText.clean("<think>only</think>  "))
        XCTAssertEqual(NovaAIText.clean("abcdef", max: 3), "abc")
    }

    func testJSONPayload() {
        XCTAssertEqual(NovaAIText.jsonPayload("```json\n{\"a\":1}\n```"), "{\"a\":1}")
        XCTAssertEqual(NovaAIText.jsonPayload("Sure! [1,2] ok"), "[1,2]")
        XCTAssertEqual(NovaAIText.jsonPayload("x {\"a\":[1]} y"), "{\"a\":[1]}")
        XCTAssertNil(NovaAIText.jsonPayload("no json here"))
    }

    func testDecodeGivesReadableErrors() {
        struct T: Decodable { var name: String }
        XCTAssertEqual(try NovaAIText.decode(T.self, from: "```{\"name\":\"x\"}```").name, "x")
        XCTAssertThrowsError(try NovaAIText.decode(T.self, from: "{\"nom\":1}")) { e in
            XCTAssertTrue((e as? NovaAIValidationError)?.reason.contains("name") == true)
        }
        XCTAssertThrowsError(try NovaAIText.decode(T.self, from: "nothing"))
    }

    func testGroundingAndPlain() {
        XCTAssertEqual(NovaAIText.numbers("0–60 in 4.50 s, 4,100 rpm"), ["0", "60", "4.5", "4100"])
        XCTAssertTrue(NovaAIText.grounded("It did 60 in 4.5", in: "0-60: 4.50 s"))
        XCTAssertFalse(NovaAIText.grounded("It did 60 in 3.9", in: "0-60: 4.50 s"))
        XCTAssertEqual(NovaAIText.plain("# **Hi**\u{0007} _there_"), "Hi there")
        XCTAssertEqual(NovaAIText.listItems("1. one\n2) two\n- three\n\n• four"), ["one", "two", "three", "four"])
    }

    func testThinkFilterAcrossChunks() {
        var f = NovaAIThinkFilter()
        var out = ""
        for c in ["Hel", "lo <thi", "nk>secret</th", "ink> world", "<", "b>"] { out += f.feed(c) }
        out += f.finish()
        XCTAssertEqual(out, "Hello  world<b>")
    }

    // MARK: Wire

    func testOllamaBodyWithSchema() throws {
        let schema = try NovaAIJSONSchema(name: "tags", json: #"{"type":"object","properties":{"tags":{"type":"array"}}}"#)
        let req = NovaAIRequest(prompt: "tag it", system: "sys", temperature: 0.2, maxTokens: 50, format: .jsonSchema(schema))
        let body = NovaAIWire.ollamaBody(req, model: "m", stream: false, maxInput: 1000)
        XCTAssertEqual(body["model"] as? String, "m")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["think"] as? Bool, false)
        XCTAssertEqual((body["format"] as? [String: Any])?["type"] as? String, "object")
        XCTAssertEqual((body["options"] as? [String: Any])?["num_predict"] as? Int, 50)
        let msgs = body["messages"] as? [[String: String]]
        XCTAssertEqual(msgs?.first?["role"], "system")
        XCTAssertTrue(msgs?.first?["content"]?.contains("JSON") == true)
    }

    func testOpenAIBodyResponseFormat() throws {
        let schema = try NovaAIJSONSchema(name: "my schema!", object: ["type": "object"])
        XCTAssertEqual(schema.name, "myschema")
        let req = NovaAIRequest(prompt: "x", format: .jsonSchema(schema))
        let native = NovaAIWire.openAIBody(req, backend: .openAI, model: "gpt", stream: true, maxInput: 100)
        let rf = native["response_format"] as? [String: Any]
        XCTAssertEqual(rf?["type"] as? String, "json_schema")
        XCTAssertEqual(native["stream"] as? Bool, true)
        // TinyLLM has no native schema: none sent, schema goes into the prompt.
        let prompt = NovaAIWire.openAIBody(req, backend: .tinyLLM, model: "t", stream: false, maxInput: 100)
        XCTAssertNil(prompt["response_format"])
        let sys = (prompt["messages"] as? [[String: String]])?.first?["content"] ?? ""
        XCTAssertTrue(sys.contains("Schema:"))
        let json = NovaAIWire.openAIBody(NovaAIRequest(prompt: "x", format: .json), backend: .openRouter, model: "m", stream: false, maxInput: 9)
        XCTAssertEqual((json["response_format"] as? [String: String])?["type"], "json_object")
    }

    func testInvalidSchemaRejected() {
        XCTAssertThrowsError(try NovaAIJSONSchema(name: "x", json: "[1]"))
        XCTAssertThrowsError(try NovaAIJSONSchema(name: "x", json: "nope"))
    }

    func testInputIsCappedPerMessage() {
        let req = NovaAIRequest(prompt: String(repeating: "a", count: 500))
        let msgs = NovaAIWire.messages(req, backend: .ollama, maxInput: 100)
        XCTAssertEqual(msgs.last?["content"]?.count, 100)
    }

    func testGatewayNativeBodyFlattens() {
        let req = NovaAIRequest(messages: [.system("Be brief"), .user("Hi"), .assistant("Hello"), .user("Sum?")])
        let body = NovaAIWire.gatewayNativeBody(req, appID: "app", maxInput: 1000)
        XCTAssertEqual(body["person"] as? String, "service")
        XCTAssertEqual(body["agent_id"] as? String, "chat")
        XCTAssertEqual(body["session_id"] as? String, "novaaikit-app")
        let m = body["message"] as? String ?? ""
        XCTAssertTrue(m.hasPrefix("Instructions: Be brief"))
        XCTAssertTrue(m.contains("Assistant: Hello"))
        XCTAssertTrue(m.hasSuffix("User: Sum?"))
    }

    func testReplyTextShapes() {
        XCTAssertEqual(NovaAIWire.replyText(Data(#"{"message":{"content":"a"}}"#.utf8)), "a")
        XCTAssertEqual(NovaAIWire.replyText(Data(#"{"choices":[{"message":{"content":"b"}}]}"#.utf8)), "b")
        XCTAssertEqual(NovaAIWire.replyText(Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"c"}]}}]}"#.utf8)), "c")
        XCTAssertEqual(NovaAIWire.replyText(Data(#"{"ok":true,"response":"d"}"#.utf8)), "d")
        XCTAssertNil(NovaAIWire.replyText(Data(#"{"ok":false,"error":"x"}"#.utf8)))
        XCTAssertEqual(NovaAIWire.replyText(Data("data: {\"choices\":[{\"delta\":{\"content\":\"e\"}}]}\ndata: [DONE]\n".utf8)), "e")
        XCTAssertEqual(NovaAIWire.replyText(Data("plain words".utf8)), "plain words")
    }

    func testStreamLines() {
        XCTAssertEqual(NovaAIWire.streamLine(#"{"message":{"content":"hi"},"done":false}"#), .text("hi"))
        XCTAssertEqual(NovaAIWire.streamLine(#"{"message":{"content":""},"done":true}"#), .done)
        XCTAssertEqual(NovaAIWire.streamLine(#"data: {"choices":[{"delta":{"content":"x"}}]}"#), .text("x"))
        XCTAssertEqual(NovaAIWire.streamLine("data: [DONE]"), .done)
        XCTAssertEqual(NovaAIWire.streamLine(": keepalive"), .ignore)
        XCTAssertEqual(NovaAIWire.streamLine("event: message"), .ignore)
        XCTAssertEqual(NovaAIWire.streamLine(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#), .ignore)
    }

    func testModelNames() {
        XCTAssertEqual(NovaAIWire.modelNames(Data(#"{"models":[{"name":"a"},{"model":"b"}]}"#.utf8)), ["a", "b"])
        XCTAssertEqual(NovaAIWire.modelNames(Data(#"{"data":[{"id":"x"}]}"#.utf8)), ["x"])
        XCTAssertEqual(NovaAIWire.modelNames(Data("garbage".utf8)), [])
    }

    func testBaseURLValidation() {
        XCTAssertEqual(NovaAIWire.baseURL("http://h:1/")?.absoluteString, "http://h:1")
        XCTAssertNil(NovaAIWire.baseURL("ftp://h"))
        XCTAssertNil(NovaAIWire.baseURL("file:///etc/passwd"))
        XCTAssertNil(NovaAIWire.baseURL("http://"))
        XCTAssertNil(NovaAIWire.baseURL("not a url"))
    }

    // MARK: Retry policy

    func testRetryPolicyDelays() {
        let p = NovaAIRetryPolicy(maxAttempts: 4, baseDelay: 0.5, multiplier: 2, maxDelay: 1.5)
        XCTAssertEqual(p.delay(afterAttempt: 1), 0.5)
        XCTAssertEqual(p.delay(afterAttempt: 2), 1.0)
        XCTAssertEqual(p.delay(afterAttempt: 3), 1.5)
        XCTAssertEqual(p.worstCaseSleep, 3.0)
        XCTAssertEqual(NovaAIRetryPolicy(maxAttempts: 99).maxAttempts, 5)
        XCTAssertEqual(NovaAIRetryPolicy(maxAttempts: 0).maxAttempts, 1)
        XCTAssertEqual(NovaAIRetryPolicy.none.worstCaseSleep, 0)
    }

    func testRetryClassification() {
        for c in [408, 429, 500, 502, 503, 504] { XCTAssertTrue(NovaAIRetry.isRetryable(NovaAIError.httpStatus(c)), "\(c)") }
        for c in [400, 401, 403, 404, 422] { XCTAssertFalse(NovaAIRetry.isRetryable(NovaAIError.httpStatus(c)), "\(c)") }
        XCTAssertTrue(NovaAIRetry.isRetryable(URLError(.networkConnectionLost)))
        XCTAssertFalse(NovaAIRetry.isRetryable(NovaAIError.timedOut))
        XCTAssertFalse(NovaAIRetry.isRetryable(URLError(.cannotConnectToHost)))
        XCTAssertTrue(NovaAIRetry.isUnreachable(URLError(.cannotConnectToHost)))
        XCTAssertTrue(NovaAIRetry.isUnreachable(NovaAIError.timedOut))
        XCTAssertFalse(NovaAIRetry.isUnreachable(NovaAIError.emptyResponse))
    }

    func testErrorDescriptionsExist() {
        let all: [NovaAIError] = [.disabled, .noBackendAvailable, .invalidURL("u"), .insecureTransport("h"), .missingKey(.openAI),
                                  .httpStatus(500), .emptyResponse, .badResponse, .timedOut, .validationFailed("v"),
                                  .invalidSchema, .allBackendsFailed("x"), .novaDisabled]
        for e in all { XCTAssertFalse((e.errorDescription ?? "").isEmpty) }
    }

    func testSourceLabels() {
        XCTAssertEqual(NovaAISource.fallback(.disabled).label, "Built-in")
        XCTAssertEqual(NovaAISource.ai(backend: .ollama, model: "m").label, "AI · Ollama (m)")
        XCTAssertTrue(NovaAISource.ai(backend: .ollama, model: "m").isAI)
    }
}

// MARK: - 1.1: providers, overrides, No Nova

extension UnitTests {
    func testCloudProviderTable() {
        let expect: [NovaAIBackend: (String, String, String)] = [
            .openAI: ("https://api.openai.com/v1", "/chat/completions", "/models"),
            .anthropic: ("https://api.anthropic.com/v1", "/messages", "/models"),
            .gemini: ("https://generativelanguage.googleapis.com/v1beta/openai", "/chat/completions", "/models"),
            .xAI: ("https://api.x.ai/v1", "/chat/completions", "/models"),
            .mistral: ("https://api.mistral.ai/v1", "/chat/completions", "/models"),
            .deepSeek: ("https://api.deepseek.com", "/chat/completions", "/models"),
            .meta: ("https://api.meta.ai/v1", "/chat/completions", "/models"),
        ]
        for (b, e) in expect {
            XCTAssertEqual(b.defaultURL, e.0, b.rawValue)
            XCTAssertEqual(b.chatPath, e.1, b.rawValue)
            XCTAssertEqual(b.modelsPath, e.2, b.rawValue)
            XCTAssertTrue(b.requiresKey, b.rawValue)
            XCTAssertEqual(b.fallbackModels.first, b.defaultModel, b.rawValue)
        }
        XCTAssertEqual(NovaAIBackend.anthropic.defaultModel, "claude-sonnet-5-5")
        XCTAssertTrue(NovaAIBackend.anthropic.fallbackModels.contains("claude-haiku-5-5"))
        XCTAssertTrue(NovaAIBackend.anthropic.speaksAnthropic)
        XCTAssertFalse(NovaAIBackend.deepSeek.supportsJSONSchema, "DeepSeek has json_object only")
    }

    func testLegacyNamesForNewProviders() {
        XCTAssertEqual(NovaAIBackend(legacyName: "Claude"), .anthropic)
        XCTAssertEqual(NovaAIBackend(legacyName: "Gemini"), .gemini)
        XCTAssertEqual(NovaAIBackend(legacyName: "Grok"), .xAI)
        XCTAssertEqual(NovaAIBackend(legacyName: "Llama API"), .meta)
        XCTAssertEqual(NovaAIBackend(legacyName: "DeepSeek"), .deepSeek)
        XCTAssertEqual(NovaAIBackend(legacyName: "ChatGPT"), .openAI)
        XCTAssertEqual(NovaAIBackend(legacyName: "googleCloud"), .auto, "the old Vertex stub had no usable key: Auto")
    }

    func testAllowNovaDefaultsOnAndRoundTrips() throws {
        XCTAssertTrue(NovaAISettings().allowNova)
        let old = try JSONDecoder().decode(NovaAISettings.self, from: Data(#"{"backend":"ollama"}"#.utf8))
        XCTAssertTrue(old.allowNova, "1.0 settings keep Nova allowed")
        let off = NovaAISettings(allowNova: false)
        XCTAssertFalse(try JSONDecoder().decode(NovaAISettings.self, from: JSONEncoder().encode(off)).allowNova)
        let bad = try JSONDecoder().decode(NovaAISettings.self, from: Data(#"{"allowNova":"no"}"#.utf8))
        XCTAssertTrue(bad.allowNova)
    }

    func testAuthHeaderShapes() {
        XCTAssertEqual(NovaAIWire.authHeaders(.anthropic, key: "k", configuration: testConfig),
                       ["x-api-key": "k", "anthropic-version": NovaAIWire.anthropicVersion])
        for b in [NovaAIBackend.openAI, .gemini, .xAI, .mistral, .deepSeek, .meta] {
            XCTAssertEqual(NovaAIWire.authHeaders(b, key: "k", configuration: testConfig), ["Authorization": "Bearer k"], b.rawValue)
        }
    }

    func testAnthropicBody() throws {
        let schema = try NovaAIJSONSchema(name: "s", object: ["type": "object"])
        let req = NovaAIRequest(messages: [.system("be brief"), .user("hi"), .assistant("yo"), .user("again")],
                                temperature: 0.2, maxTokens: 77, format: .jsonSchema(schema))
        let body = NovaAIWire.anthropicBody(req, model: "claude-haiku-5-5", stream: true, maxInput: 1000)
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 77)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil(body["temperature"], "sampling fields are rejected by current Claude models")
        XCTAssertTrue((body["system"] as? String)?.hasPrefix("be brief") == true)
        let msgs = body["messages"] as? [[String: String]] ?? []
        XCTAssertEqual(msgs.map { $0["role"] ?? "" }, ["user", "assistant", "user"])
        let out = body["output_config"] as? [String: Any]
        XCTAssertEqual(out?["effort"] as? String, "low")
        XCTAssertEqual((out?["format"] as? [String: Any])?["type"] as? String, "json_schema")
        var r = NovaAIRequest(prompt: "x")
        r.reasoning = true
        let think = NovaAIWire.anthropicBody(r, model: "m", stream: false, maxInput: 9)
        XCTAssertEqual((think["output_config"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertNil(think["system"])
    }

    func testOpenAICompatibleBodiesPerProvider() throws {
        let req = NovaAIRequest(prompt: "x", temperature: 0.3, maxTokens: 50)
        let oa = NovaAIWire.openAIBody(req, backend: .openAI, model: "gpt-6-luna", stream: false, maxInput: 99)
        XCTAssertEqual(oa["max_completion_tokens"] as? Int, 50)
        XCTAssertNil(oa["max_tokens"])
        XCTAssertNil(oa["temperature"])
        for b in [NovaAIBackend.xAI, .mistral, .deepSeek, .meta, .gemini] {
            let body = NovaAIWire.openAIBody(req, backend: b, model: "m", stream: false, maxInput: 99)
            XCTAssertEqual(body["temperature"] as? Double, 0.3, b.rawValue)
            XCTAssertEqual(body["max_tokens"] as? Int, 50, b.rawValue)
        }
        XCTAssertEqual(NovaAIWire.openAIBody(req, backend: .gemini, model: "m", stream: false, maxInput: 9)["reasoning_effort"] as? String, "low")
        XCTAssertNil(NovaAIWire.openAIBody(req, backend: .xAI, model: "m", stream: false, maxInput: 9)["reasoning_effort"])
        let schema = NovaAIRequest(prompt: "x", format: .jsonSchema(try NovaAIJSONSchema(name: "s", object: ["type": "object"])))
        XCTAssertNotNil(NovaAIWire.openAIBody(schema, backend: .mistral, model: "m", stream: false, maxInput: 99)["response_format"])
        XCTAssertNil(NovaAIWire.openAIBody(schema, backend: .deepSeek, model: "m", stream: false, maxInput: 99)["response_format"])
    }

    func testAnthropicReplyAndStreamShapes() {
        let reply = #"{"content":[{"type":"thinking","thinking":"secret"},{"type":"text","text":"Hel"},{"type":"text","text":"lo"}]}"#
        XCTAssertEqual(NovaAIWire.replyText(Data(reply.utf8)), "Hello")
        XCTAssertEqual(NovaAIWire.streamLine(#"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"A"}}"#), .text("A"))
        XCTAssertEqual(NovaAIWire.streamLine(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hm"}}"#), .ignore)
        XCTAssertEqual(NovaAIWire.streamLine(#"data: {"type":"message_start","message":{"content":[]}}"#), .ignore)
        XCTAssertEqual(NovaAIWire.streamLine(#"data: {"type":"ping"}"#), .ignore)
        XCTAssertEqual(NovaAIWire.streamLine(#"data: {"type":"message_stop"}"#), .done)
    }

    func testRequestOverrideInitializer() {
        let r = NovaAIRequest(prompt: "move?", system: "chess", backend: .anthropic, model: "claude-haiku-5-5")
        XCTAssertEqual(r.backend, .anthropic)
        XCTAssertEqual(r.model, "claude-haiku-5-5")
        XCTAssertEqual(r.messages.count, 2)
    }
}
