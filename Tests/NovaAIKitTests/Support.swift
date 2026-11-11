//
//  Support.swift
//  NovaAIKitTests
//
//  URLProtocol stub (no real network, no real keys) and helpers.
//

import Foundation
import XCTest
@testable import NovaAIKit

/// One canned reply.
struct StubReply: Sendable {
    var status: Int = 200
    var chunks: [Data] = []
    var error: URLError?
    var headers: [String: String] = ["Content-Type": "application/json"]

    static func json(_ s: String, status: Int = 200) -> StubReply { StubReply(status: status, chunks: [Data(s.utf8)]) }
    static func status(_ code: Int) -> StubReply { StubReply(status: code, chunks: [Data("{}".utf8)]) }
    static func fail(_ code: URLError.Code) -> StubReply { StubReply(error: URLError(code)) }
    static func lines(_ lines: [String]) -> StubReply { StubReply(chunks: lines.map { Data(($0 + "\n").utf8) }) }

    static func ollama(_ text: String) -> StubReply {
        .json(#"{"model":"m","message":{"role":"assistant","content":\#(quoted(text))},"done":true}"#)
    }
    static func openAI(_ text: String) -> StubReply {
        .json(#"{"choices":[{"index":0,"message":{"role":"assistant","content":\#(quoted(text))}}]}"#)
    }
    static func quoted(_ s: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)!.dropFirst().dropLast().description
    }
}

/// A request the stub saw, with its body read out of the stream.
struct SeenRequest: Sendable {
    var url: URL
    var method: String
    var headers: [String: String]
    var body: Data

    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
    var bodyText: String { String(decoding: body, as: UTF8.self) }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (SeenRequest) -> StubReply)?
    nonisolated(unsafe) private static var seen: [SeenRequest] = []
    /// Requests from sessions made before the last `reset()` (late tasks of an earlier test) are refused unrecorded.
    nonisolated(unsafe) private static var token = UUID().uuidString
    static let tokenHeader = "X-NovaAIKit-Test-Session"

    static func respond(_ h: @escaping @Sendable (SeenRequest) -> StubReply) {
        lock.lock(); handler = h; seen = []; lock.unlock()
    }
    static var requests: [SeenRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    static func reset() { lock.lock(); handler = nil; seen = []; token = UUID().uuidString; lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let seenReq = SeenRequest(url: request.url!, method: request.httpMethod ?? "GET",
                                  headers: request.allHTTPHeaderFields ?? [:], body: body)
        Self.lock.lock()
        let current = request.value(forHTTPHeaderField: Self.tokenHeader) == Self.token
        if current { Self.seen.append(seenReq) }
        let h = current ? Self.handler : nil
        Self.lock.unlock()
        let reply = h?(seenReq) ?? StubReply.fail(.cannotConnectToHost)
        if let e = reply.error {
            client?.urlProtocol(self, didFailWithError: e)
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        for c in reply.chunks { client?.urlProtocol(self, didLoad: c) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        lock.lock(); c.httpAdditionalHeaders = [tokenHeader: token]; lock.unlock()
        return URLSession(configuration: c)
    }
}

/// Records sleeps instead of sleeping.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var d: [TimeInterval] = []
    var delays: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return d }
    func record(_ t: TimeInterval) { lock.lock(); d.append(t); lock.unlock() }
    var sleeper: NovaAISleeper { { [self] t in record(t) } }
}

let testConfig = NovaAIConfiguration(appID: "novaaikit-tests", appName: "NovaAIKit Tests")

/// Base class: stub reset, a stubbed session, memory keys and storage.
class StubbedTestCase: XCTestCase {
    var keys: NovaAIMemoryKeyStore!
    var storage: NovaAIMemoryStorage!
    var sleeps: SleepRecorder!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        keys = NovaAIMemoryKeyStore()
        storage = NovaAIMemoryStorage()
        sleeps = SleepRecorder()
    }

    @MainActor
    func makeAI(_ settings: NovaAISettings = NovaAISettings(), config: NovaAIConfiguration = testConfig,
                localModel: (any NovaAILocalModel)? = nil) -> NovaAI {
        storage.save(settings)
        return NovaAI(configuration: config, storage: storage, keyStore: keys, session: StubURLProtocol.session(),
                      sleep: sleeps.sleeper, localModel: localModel)
    }

    func makeEngine(_ settings: NovaAISettings = NovaAISettings(), config: NovaAIConfiguration = testConfig,
                    health: NovaAIHealth? = nil) -> NovaAIEngine {
        NovaAIEngine(configuration: config, settings: settings, keys: NovaAIKeys(configuration: config, store: keys),
                     session: StubURLProtocol.session(), health: health, sleep: sleeps.sleeper)
    }

    func setKey(_ k: String, _ b: NovaAIBackend, config: NovaAIConfiguration = testConfig) {
        keys.write(k, service: config.keychainService(for: b), account: NovaAIConfiguration.keychainAccount)
    }

    /// Settings with one backend selected.
    func only(_ b: NovaAIBackend, url: String? = nil) -> NovaAISettings {
        var s = NovaAISettings(backend: b)
        if let url { s.setURL(url, for: b) }
        return s
    }
}
