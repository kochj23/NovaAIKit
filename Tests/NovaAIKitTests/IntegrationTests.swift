//
//  IntegrationTests.swift — against a live local Ollama (http://localhost:11434). Every test skips cleanly when
//  it isn't reachable. No keys are used. Override the model with NOVAAIKIT_TEST_MODEL.
//

import XCTest
@testable import NovaAIKit

final class IntegrationTests: XCTestCase {
    static let base = "http://localhost:11434"

    /// A chat model on the local Ollama, or nil (→ skip).
    static func liveModel() async throws -> String {
        var r = URLRequest(url: URL(string: Self.base + "/api/tags")!)
        r.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { throw XCTSkip("Ollama not reachable on localhost:11434") }
        let names = NovaAIWire.modelNames(data).filter { !$0.contains("embed") && !$0.contains("-vl") && !$0.contains("vl:") }
        if let env = ProcessInfo.processInfo.environment["NOVAAIKIT_TEST_MODEL"], names.contains(env) { return env }
        for preferred in ["llama3.2:3b", "qwen3:8b", "qwen3:4b", "gemma3:4b"] where names.contains(preferred) { return preferred }
        guard let any = names.first else { throw XCTSkip("Ollama has no chat model") }
        return any
    }

    @MainActor
    func makeAI(model: String) -> NovaAI {
        var s = NovaAISettings(backend: .ollama, timeout: 240)
        s.setModel(model, for: .ollama)
        return NovaAI(configuration: NovaAIConfiguration(appID: "novaaikit-integration", appName: "NovaAIKit Integration"),
                      storage: NovaAIMemoryStorage(s), keyStore: NovaAIMemoryKeyStore())
    }

    @MainActor
    func testLiveProbeAndModelList() async throws {
        let model = try await Self.liveModel()
        let ai = makeAI(model: model)
        let p = await ai.testConnection(.ollama)
        XCTAssertTrue(p.reachable, p.detail)
        let models = await ai.listModels(for: .ollama)
        XCTAssertTrue(models.contains(model))
        await ai.refreshStatus()
        XCTAssertEqual(ai.status.state, .online)
        XCTAssertEqual(ai.status.activeBackend, .ollama)
    }

    @MainActor
    func testLiveGenerateWithValidation() async throws {
        let model = try await Self.liveModel()
        let ai = makeAI(model: model)
        let r = await ai.generate(NovaAIRequest(prompt: "What is 2 + 3? Answer with the number only.", temperature: 0, maxTokens: 400),
                                  validate: { s -> Int in
                                      guard let n = NovaAIText.numbers(s).compactMap(Int.init).first else { throw NovaAIValidationError("no number") }
                                      return n
                                  }, fallback: { -1 })
        XCTAssertTrue(r.isAI, "\(r.source)")
        XCTAssertEqual(r.value, 5)
        XCTAssertFalse(r.response?.text.contains("<think>") ?? true)
    }

    struct Person: Codable, Sendable { var name: String; var age: Int }

    @MainActor
    func testLiveStructuredOutput() async throws {
        let model = try await Self.liveModel()
        let ai = makeAI(model: model)
        let schema = try NovaAIJSONSchema(name: "person", object: [
            "type": "object", "required": ["name", "age"],
            "properties": ["name": ["type": "string"], "age": ["type": "integer"]],
        ])
        let r = await ai.structured(Person.self, NovaAIRequest(prompt: "Extract the person: 'Ada Lovelace was 36.'", temperature: 0, maxTokens: 400),
                                    schema: schema) { Person(name: "?", age: 0) }
        XCTAssertTrue(r.isAI, "\(r.source)")
        XCTAssertTrue(r.value.name.contains("Ada"))
        XCTAssertEqual(r.value.age, 36)
    }

    @MainActor
    func testLiveStreaming() async throws {
        let model = try await Self.liveModel()
        let ai = makeAI(model: model)
        var chunks = 0
        var text = ""
        for try await d in ai.stream(NovaAIRequest(prompt: "Count from 1 to 5, separated by spaces.", temperature: 0, maxTokens: 400)) {
            chunks += 1
            text += d
        }
        XCTAssertGreaterThan(chunks, 0)
        XCTAssertTrue(text.contains("3"), text)
        XCTAssertFalse(text.contains("<think>"))
    }
}

// MARK: - 1.1: live local Ollama with No Nova and per-request override

extension IntegrationTests {
    @MainActor
    func testLiveNoNovaAutoAndOverride() async throws {
        let model = try await Self.liveModel()
        var s = NovaAISettings(backend: .auto, timeout: 240, allowNova: false)
        s.setURL("http://127.0.0.1:1", for: .mlx)          // keep Auto off any other local server
        let ai = NovaAI(configuration: NovaAIConfiguration(appID: "novaaikit-integration", appName: "NovaAIKit Integration"),
                        storage: NovaAIMemoryStorage(s), keyStore: NovaAIMemoryKeyStore())
        let r = try await ai.complete(NovaAIRequest(prompt: "Say OK.", maxTokens: 400, backend: .ollama, model: model))
        XCTAssertEqual(r.backend, .ollama)
        XCTAssertEqual(r.model, model)
        do { _ = try await ai.complete(NovaAIRequest(prompt: "x", backend: .novaGateway)); XCTFail() } catch {
            XCTAssertEqual(error as? NovaAIError, .novaDisabled)
        }
        await ai.refreshStatus()
        XCTAssertNil(ai.status.reachability[.novaGateway], "Nova never probed")
    }
}
