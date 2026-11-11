//
//  PerformanceTests.swift — hot paths stay cheap; a dead fleet never blocks the app.
//

import XCTest
@testable import NovaAIKit

final class PerformanceTests: StubbedTestCase {
    /// Wall-clock budget helper (generous so CI noise doesn't flake).
    func within(_ seconds: TimeInterval, _ body: () throws -> Void) rethrows {
        let start = Date()
        try body()
        let took = Date().timeIntervalSince(start)
        XCTAssertLessThan(took, seconds, "took \(took)s")
    }

    func testReplyParsingThroughput() {
        let data = Data(#"{"message":{"role":"assistant","content":"<think>a</think>The quick brown fox jumps over the lazy dog."}}"#.utf8)
        within(2) {
            for _ in 0..<5_000 { _ = NovaAIWire.replyText(data).flatMap { NovaAIText.clean($0) } }
        }
    }

    func testThinkFilterOnLargeStream() {
        let chunk = "word <think>hidden</think> more text "
        within(3) {
            var f = NovaAIThinkFilter()
            var n = 0
            for _ in 0..<20_000 { n += f.feed(chunk).count }
            XCTAssertGreaterThan(n, 0)
        }
    }

    func testJSONExtractionOnLargeReply() {
        let big = String(repeating: "chatter ", count: 50_000) + #"{"a":1}"# + " trailing"
        within(1) { XCTAssertEqual(NovaAIText.jsonPayload(big), #"{"a":1}"#) }
    }

    func testCandidateListIsCheap() {
        var s = NovaAISettings()
        s.extraOllamaEndpoints = (0..<20).map { NovaAIEndpoint(url: "http://h\($0):11434", model: "m") }
        let engine = makeEngine(s)
        within(2) { for _ in 0..<2_000 { _ = engine.candidates() } }
    }

    func testDeadFleetFailsFastWithoutSleeping() async {
        StubURLProtocol.respond { _ in .fail(.cannotConnectToHost) }
        let start = Date()
        _ = try? await makeEngine().complete(NovaAIRequest(prompt: "x"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertTrue(sleeps.delays.isEmpty, "refused connections fail over at once, no backoff")
    }

    @MainActor
    func testFallbackIsImmediateWhenOff() async {
        let ai = makeAI(NovaAISettings(enabled: false))
        let start = Date()
        for _ in 0..<1_000 { _ = await ai.text(NovaAIRequest(prompt: "x")) { "f" } }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testConcurrentCallsAreSafe() async throws {
        StubURLProtocol.respond { _ in .ollama("ok") }
        let engine = makeEngine(only(.ollama))
        let start = Date()
        let results = try await withThrowingTaskGroup(of: String.self) { g in
            for i in 0..<50 { g.addTask { try await engine.complete(NovaAIRequest(prompt: "\(i)")).text } }
            return try await g.reduce(into: [String]()) { $0.append($1) }
        }
        XCTAssertEqual(results.count, 50)
        XCTAssertTrue(results.allSatisfy { $0 == "ok" })
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testWorstCaseRetrySleepIsBounded() {
        XCTAssertLessThanOrEqual(NovaAIRetryPolicy.network.worstCaseSleep, 1)
        XCTAssertLessThanOrEqual(NovaAIRetryPolicy(maxAttempts: 5, baseDelay: 10, maxDelay: 4).worstCaseSleep, 16)
    }

    func testMeasureRequestBuilding() throws {
        let engine = makeEngine()
        let c = NovaAICandidate(backend: .ollama, baseURL: "http://localhost:11434", model: "m")
        let req = NovaAIRequest(prompt: String(repeating: "x", count: 10_000), system: "s")
        measure {
            for _ in 0..<200 { _ = try? engine.chatRequest(c, req, stream: false) }
        }
    }
}
