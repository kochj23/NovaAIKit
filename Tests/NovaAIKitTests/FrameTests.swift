//
//  FrameTests.swift — UI state: the status model's transitions and labels, the indicator colors, persistence on
//  edit, and the SwiftUI views rendering (macOS) in every state.
//

import XCTest
import SwiftUI
@testable import NovaAIKit

final class FrameTests: StubbedTestCase {
    func testStatusLabels() {
        var s = NovaAIStatus()
        XCTAssertEqual(s.label, "AI not checked yet")
        s.state = .off
        XCTAssertEqual(s.label, "AI off · built-in answers")
        s.state = .offline
        XCTAssertEqual(s.label, "AI offline · built-in answers")
        s.state = .checking
        XCTAssertEqual(s.label, "Checking AI…")
        s.state = .online
        s.activeBackend = .ollama
        s.host = "localhost"
        s.lastLatency = 0.4204
        XCTAssertEqual(s.label, "Ollama (localhost) · online · 420 ms")
        XCTAssertTrue(s.isReachable)
    }

    func testIndicatorColors() {
        XCTAssertEqual(NovaAIStatusIndicator.color(.online), .green)
        XCTAssertEqual(NovaAIStatusIndicator.color(.offline), .orange)
        XCTAssertEqual(NovaAIStatusIndicator.color(.off), .gray)
        XCTAssertEqual(NovaAIStatusIndicator.color(.unknown), .gray)
    }

    @MainActor
    func testStatusTransitions() async {
        StubURLProtocol.respond { _ in .ollama("ok") }
        let ai = makeAI(only(.ollama))
        XCTAssertEqual(ai.status.state, .unknown)
        _ = try? await ai.complete(NovaAIRequest(prompt: "x"))
        XCTAssertEqual(ai.status.state, .online)
        XCTAssertEqual(ai.status.activeModel, "qwen3:8b")
        XCTAssertNotNil(ai.status.lastLatency)
        ai.isEnabled = false
        XCTAssertEqual(ai.status.state, .off)
        XCTAssertNil(ai.status.activeBackend)
        ai.isEnabled = true
        XCTAssertEqual(ai.status.state, .unknown)
        StubURLProtocol.respond { _ in .fail(.cannotConnectToHost) }
        _ = try? await ai.complete(NovaAIRequest(prompt: "x"))
        XCTAssertEqual(ai.status.state, .offline)
        XCTAssertEqual(ai.status.lastError, "connection refused")
        ai.settings.backend = .tinyLLM
        XCTAssertEqual(ai.status.state, .unknown, "backend change resets status")
    }

    @MainActor
    func testRefreshShowsCheckingThenResult() async {
        StubURLProtocol.respond { _ in .fail(.cannotConnectToHost) }
        let ai = makeAI(only(.ollama))
        var seen: [NovaAIStatus.State] = []
        let sub = ai.$status.sink { seen.append($0.state) }
        await ai.refreshStatus()
        sub.cancel()
        XCTAssertTrue(seen.contains(.checking))
        XCTAssertEqual(seen.last, .offline)
        XCTAssertEqual(ai.status.reachability[.ollama], false)
    }

    @MainActor
    func testRefreshWhenOffDoesNotProbe() async {
        let ai = makeAI(NovaAISettings(enabled: false))
        await ai.refreshStatus()
        XCTAssertEqual(ai.status.state, .off)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    @MainActor
    func testLastSourceTracksAIOrFallback() async {
        StubURLProtocol.respond { _ in .ollama("ai") }
        let ai = makeAI(only(.ollama))
        _ = await ai.text(NovaAIRequest(prompt: "x")) { "f" }
        XCTAssertEqual(ai.status.lastSource, .ai(backend: .ollama, model: "qwen3:8b"))
        ai.isEnabled = false
        _ = await ai.text(NovaAIRequest(prompt: "x")) { "f" }
        XCTAssertEqual(ai.status.lastSource, .fallback(.disabled))
    }

    @MainActor
    func testEditsPersistAndPublish() {
        let ai = makeAI()
        var changes = 0
        let sub = ai.objectWillChange.sink { changes += 1 }
        ai.settings.setURL("http://nova-core8:11434", for: .ollama)
        ai.settings.backend = .ollama
        sub.cancel()
        XCTAssertGreaterThanOrEqual(changes, 2)
        XCTAssertEqual(storage.load()?.url(for: .ollama), "http://nova-core8:11434")
        XCTAssertEqual(storage.load()?.backend, .ollama)
    }

    @MainActor
    func testKeyChangeBumpsVersionForViews() {
        let ai = makeAI()
        let v = ai.keysVersion
        ai.setAPIKey("k", for: .openAI)
        XCTAssertEqual(ai.keysVersion, v + 1)
    }

    #if os(macOS)
    @MainActor
    func testViewsRenderInEveryState() {
        StubURLProtocol.respond { _ in .fail(.cannotConnectToHost) }
        for settings in [NovaAISettings(), NovaAISettings(enabled: false), only(.openRouter), only(.ollama)] {
            let ai = makeAI(settings)
            let host = NSHostingView(rootView: NovaAISettingsView(ai: ai, footer: "When AI is off the app uses built-in answers.")
                .frame(width: 520, height: 800))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.width, 0)
            let indicator = NSHostingView(rootView: NovaAIStatusIndicator(ai: ai, checksOnAppear: false))
            indicator.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(indicator.fittingSize.width, 0)
            let dot = NSHostingView(rootView: NovaAIStatusIndicator(ai: ai, showsLabel: false, checksOnAppear: false))
            XCTAssertLessThan(dot.fittingSize.width, indicator.fittingSize.width)
        }
    }
    #endif
}
