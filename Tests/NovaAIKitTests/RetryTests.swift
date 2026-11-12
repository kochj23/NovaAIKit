//
//  RetryTests.swift — bounded retries with backoff, failover, health skipping, cancellation.
//

import XCTest
@testable import NovaAIKit

final class RetryTests: StubbedTestCase {
    func testTransient503RetriedThenSucceeds() async throws {
        let n = NovaAICounter()
        StubURLProtocol.respond { _ in n.increment(); return n.value == 1 ? .status(503) : .ollama("ok") }
        let r = try await makeEngine(only(.ollama)).complete(NovaAIRequest(prompt: "x"))
        XCTAssertEqual(r.text, "ok")
        XCTAssertEqual(r.attempts, 2)
        XCTAssertEqual(sleeps.delays, [0.5])
    }

    func test429Retried() async throws {
        let n = NovaAICounter()
        StubURLProtocol.respond { _ in n.increment(); return n.value == 1 ? .status(429) : .ollama("ok") }
        _ = try await makeEngine(only(.ollama)).complete(NovaAIRequest(prompt: "x"))
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testDroppedConnectionRetried() async throws {
        let n = NovaAICounter()
        StubURLProtocol.respond { _ in n.increment(); return n.value == 1 ? .fail(.networkConnectionLost) : .ollama("ok") }
        _ = try await makeEngine(only(.ollama)).complete(NovaAIRequest(prompt: "x"))
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testClientErrorNotRetried() async {
        StubURLProtocol.respond { _ in .status(400) }
        do {
            _ = try await makeEngine(only(.ollama)).complete(NovaAIRequest(prompt: "x"))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? NovaAIError, .httpStatus(400))
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertTrue(sleeps.delays.isEmpty)
    }

    func testRetriesAreBounded() async {
        StubURLProtocol.respond { _ in .status(500) }
        var config = testConfig
        config.retry = NovaAIRetryPolicy(maxAttempts: 3, baseDelay: 0.25)
        await XCTAssertThrowsAsync(try await makeEngine(only(.ollama), config: config).complete(NovaAIRequest(prompt: "x")))
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        XCTAssertEqual(sleeps.delays, [0.25, 0.5])
    }

    func testTimeoutFailsOverWithoutRetry() async throws {
        StubURLProtocol.respond { r in r.url.port == 11434 ? .fail(.timedOut) : .openAI("from mlx") }
        let r = try await makeEngine().complete(NovaAIRequest(prompt: "x"))
        XCTAssertEqual(r.backend, .mlx)
        XCTAssertEqual(StubURLProtocol.requests.filter { $0.url.port == 11434 }.count, 1, "a timeout is not retried")
    }

    func testTimeoutMappedToNovaAIError() async {
        StubURLProtocol.respond { _ in .fail(.timedOut) }
        do {
            _ = try await makeEngine(only(.ollama)).complete(NovaAIRequest(prompt: "x"))
            XCTFail()
        } catch { XCTAssertEqual(error as? NovaAIError, .timedOut) }
    }

    func testFailedServerSkippedWithinTTLThenRetried() async throws {
        final class Clock: @unchecked Sendable { var t = Date() }
        let c = Clock()
        let health = NovaAIHealth(ttl: 60, now: { c.t })
        StubURLProtocol.respond { r in r.url.port == 11434 ? .fail(.cannotConnectToHost) : .openAI("mlx") }
        let engine = makeEngine(NovaAISettings(), health: health)
        _ = try await engine.complete(NovaAIRequest(prompt: "1"))
        XCTAssertEqual(health.status("http://localhost:11434"), false)
        StubURLProtocol.respond { r in r.url.port == 11434 ? .ollama("ollama back") : .openAI("mlx") }
        let second = try await engine.complete(NovaAIRequest(prompt: "2"))
        XCTAssertEqual(second.backend, .mlx, "skipped within TTL")
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url.port == 11434 })
        c.t = c.t.addingTimeInterval(61)
        let third = try await engine.complete(NovaAIRequest(prompt: "3"))
        XCTAssertEqual(third.backend, .ollama, "tried again after TTL")
    }

    func testAllMarkedDownStillTriesSomething() async throws {
        let health = NovaAIHealth()
        health.mark("http://localhost:11434", ok: false)
        StubURLProtocol.respond { _ in .ollama("ok") }
        let r = try await makeEngine(only(.ollama), health: health).complete(NovaAIRequest(prompt: "x"))
        XCTAssertEqual(r.text, "ok")
    }

    func testEveryBackendFailingGivesAllBackendsFailed() async {
        StubURLProtocol.respond { _ in .fail(.cannotConnectToHost) }
        do {
            _ = try await makeEngine().complete(NovaAIRequest(prompt: "x"))
            XCTFail()
        } catch {
            guard case NovaAIError.allBackendsFailed = error else { return XCTFail("\(error)") }
        }
        // ollama, mlx, tinychat, tinyllm (same URL as tinychat but a different path → separate candidate), openwebui, gateway
        XCTAssertEqual(Set(StubURLProtocol.requests.map { $0.url.port }), [11434, 8081, 8000, 8080, 18792])
    }

    func testCancellationStopsImmediately() async {
        StubURLProtocol.respond { _ in .status(503) }
        let engine = makeEngine(only(.ollama))
        let task = Task { try await engine.complete(NovaAIRequest(prompt: "x")) }
        task.cancel()
        let result = await task.result
        if case .success = result { XCTFail("cancelled task must not succeed") }
    }

    func testRetryRunCountsAttempts() async throws {
        let n = NovaAICounter()
        let attempts = NovaAICounter()
        let v: Int = try await NovaAIRetry.run(.network, sleep: { _ in }, onAttempt: { attempts.increment() }) {
            n.increment()
            if n.value < 2 { throw NovaAIError.httpStatus(502) }
            return 7
        }
        XCTAssertEqual(v, 7)
        XCTAssertEqual(attempts.value, 2)
    }

    func testStreamingRetriesBeforeFirstByte() async throws {
        let n = NovaAICounter()
        StubURLProtocol.respond { _ in
            n.increment()
            return n.value == 1 ? .status(503) : .lines([#"{"message":{"content":"hi"},"done":false}"#, #"{"message":{"content":""},"done":true}"#])
        }
        var text = ""
        for try await e in makeEngine(only(.ollama)).stream(NovaAIRequest(prompt: "x")) {
            if case .delta(let d) = e { text += d }
        }
        XCTAssertEqual(text, "hi")
        XCTAssertEqual(sleeps.delays, [0.5])
    }
}

// MARK: - 1.1

extension RetryTests {
    func testOverrideRetriesOnlyItsOwnBackend() async {
        setKey("sk-ant", .anthropic)
        StubURLProtocol.respond { _ in .status(529) }
        do {
            _ = try await makeEngine().complete(NovaAIRequest(prompt: "x", backend: .anthropic, model: "claude-haiku-5-5"))
            XCTFail()
        } catch { XCTAssertEqual(error as? NovaAIError, .httpStatus(529), "the single backend's own error, no failover") }
        XCTAssertEqual(StubURLProtocol.requests.count, NovaAIRetryPolicy.network.maxAttempts)
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.url.host == "api.anthropic.com" })
    }

    func testCloud429RetriedThenSucceeds() async throws {
        setKey("sk-x", .xAI)
        let n = NovaAICounter()
        StubURLProtocol.respond { _ in n.increment(); return n.value == 1 ? .status(429) : .openAI("grok") }
        let r = try await makeEngine(only(.xAI)).complete(NovaAIRequest(prompt: "x"))
        XCTAssertEqual(r.text, "grok")
        XCTAssertEqual(r.attempts, 2)
        XCTAssertEqual(sleeps.delays, [0.5])
    }

    func testAutoWithoutNovaFailsOverPastGatewayToCloud() async throws {
        setKey("sk-g", .gemini)
        StubURLProtocol.respond { r in r.url.host == cloudHosts[.gemini] ? .openAI("gemini") : .fail(.cannotConnectToHost) }
        let r = try await makeEngine(NovaAISettings(allowNova: false)).complete(NovaAIRequest(prompt: "x"))
        XCTAssertEqual(r.backend, .gemini)
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url.port == 18792 })
    }

    func testNovaDisabledIsNotRetried() async {
        do {
            _ = try await makeEngine(NovaAISettings(backend: .novaGateway, allowNova: false)).complete(NovaAIRequest(prompt: "x"))
            XCTFail()
        } catch { XCTAssertEqual(error as? NovaAIError, .novaDisabled) }
        XCTAssertTrue(sleeps.delays.isEmpty)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }
}
