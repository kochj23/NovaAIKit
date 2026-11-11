//
//  NovaAIEngine.swift
//  NovaAIKit
//
//  The network engine: builds the candidate list (chosen backend, or Auto's fixed order), skips servers that just
//  failed, retries transient errors with backoff, fails over, streams, lists models and probes reachability.
//  A Sendable value with everything injected (URLSession, key store, health, sleep), so tests never reach a real
//  server or the Keychain. `NovaAI` (the observable façade) owns the settings and makes one per call.
//
//  Copyright © 2026 Jordan Koch.
//

import Foundation

/// An in-process model the app plugs in for the `mlx` backend (e.g. an mlx-swift engine). Without one, `mlx`
/// talks to `mlx_lm.server` over HTTP.
public protocol NovaAILocalModel: Sendable {
    /// Whether the model can answer now (loaded, enough memory…).
    func isAvailable() async -> Bool
    /// One complete answer.
    func complete(messages: [NovaAIMessage], temperature: Double, maxTokens: Int) async throws -> String
}

/// One place a request can go.
public struct NovaAICandidate: Sendable, Equatable, Hashable {
    public var backend: NovaAIBackend
    /// Base URL (no trailing slash), or `in-process` for a plugged-in local model.
    public var baseURL: String
    public var model: String
}

/// Result of probing one backend.
public struct NovaAIProbe: Sendable, Equatable {
    public var backend: NovaAIBackend
    public var reachable: Bool
    /// The base URL that answered (or was tried last).
    public var baseURL: String?
    public var latency: TimeInterval?
    /// Short, key-free description ("HTTP 200", "no API key", "timed out").
    public var detail: String

    public init(backend: NovaAIBackend, reachable: Bool, baseURL: String? = nil, latency: TimeInterval? = nil, detail: String) {
        self.backend = backend
        self.reachable = reachable
        self.baseURL = baseURL
        self.latency = latency
        self.detail = detail
    }
}

public struct NovaAIEngine: Sendable {
    public var configuration: NovaAIConfiguration
    public var settings: NovaAISettings
    public var keys: NovaAIKeys
    public var session: URLSession
    public var health: NovaAIHealth
    public var sleep: NovaAISleeper
    public var localModel: (any NovaAILocalModel)?

    static let inProcess = "in-process"

    public init(configuration: NovaAIConfiguration, settings: NovaAISettings, keys: NovaAIKeys,
                session: URLSession = .shared, health: NovaAIHealth? = nil, sleep: @escaping NovaAISleeper = NovaAIRetry.taskSleep,
                localModel: (any NovaAILocalModel)? = nil) {
        self.configuration = configuration
        self.settings = settings
        self.keys = keys
        self.session = session
        self.health = health ?? NovaAIHealth(ttl: configuration.healthTTL)
        self.sleep = sleep
        self.localModel = localModel
    }

    // MARK: - Candidates

    /// The backends tried, in order: the request's override, the chosen backend, or Auto's fixed order.
    public func chain(for request: NovaAIRequest? = nil) -> [NovaAIBackend] {
        if let b = request?.backend, b != .auto { return b.isSupportedOnThisPlatform ? [b] : [] }
        if settings.backend == .auto { return NovaAIBackend.autoOrder }
        return settings.backend.isSupportedOnThisPlatform ? [settings.backend] : []
    }

    /// Every candidate in order. Keyed backends join only when a key is stored (no key: nothing is sent there).
    public func candidates(for request: NovaAIRequest? = nil) -> [NovaAICandidate] {
        var out: [NovaAICandidate] = []
        for b in chain(for: request) {
            if b.requiresKey, !keys.hasKey(for: b) { continue }
            let model = request?.model ?? settings.model(for: b)
            if b == .mlx, localModel != nil {
                out.append(NovaAICandidate(backend: b, baseURL: Self.inProcess, model: model))
                continue
            }
            out.append(NovaAICandidate(backend: b, baseURL: settings.url(for: b), model: model))
            if b == .ollama {
                for e in settings.extraOllamaEndpoints {
                    out.append(NovaAICandidate(backend: b, baseURL: NovaAISettings(urls: ["ollama": e.url]).url(for: .ollama),
                                               model: request?.model ?? (e.model.isEmpty ? model : e.model)))
                }
            }
        }
        var seen = Set<NovaAICandidate>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Candidates minus the ones that failed within the health TTL (all of them if every one did).
    func liveCandidates(for request: NovaAIRequest) throws -> [NovaAICandidate] {
        guard settings.enabled else { throw NovaAIError.disabled }
        let all = candidates(for: request)
        if all.isEmpty {
            let chain = chain(for: request)
            if chain.count == 1, chain[0].requiresKey { throw NovaAIError.missingKey(chain[0]) }
            throw NovaAIError.noBackendAvailable
        }
        let healthy = all.filter { health.status($0.baseURL) != false }
        return healthy.isEmpty ? all : healthy
    }

    // MARK: - Complete

    /// One answer, with retries per backend and failover across candidates.
    /// - Throws: `NovaAIError` (`.disabled`, `.missingKey`, `.noBackendAvailable`, the single backend's error, or
    ///   `.allBackendsFailed`), or `CancellationError`.
    public func complete(_ request: NovaAIRequest) async throws -> NovaAIResponse {
        let list = try liveCandidates(for: request)
        let counter = NovaAICounter()
        var lastError: Error = NovaAIError.noBackendAvailable
        for c in list {
            try Task.checkCancellation()
            let started = Date()
            do {
                let text = try await NovaAIRetry.run(configuration.retry, sleep: sleep, onAttempt: { counter.increment() }) {
                    try await self.send(c, request)
                }
                if c.baseURL != Self.inProcess { health.mark(c.baseURL, ok: true) }
                return NovaAIResponse(text: text, backend: c.backend, model: c.model, endpoint: c.baseURL,
                                      latency: Date().timeIntervalSince(started), attempts: counter.value)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if NovaAIRetry.isUnreachable(error), c.baseURL != Self.inProcess { health.mark(c.baseURL, ok: false) }
                lastError = error
            }
        }
        if list.count == 1 { throw lastError }
        throw NovaAIError.allBackendsFailed((lastError as? LocalizedError)?.errorDescription ?? "\(lastError)")
    }

    /// One attempt against one candidate: the cleaned reply text.
    func send(_ c: NovaAICandidate, _ request: NovaAIRequest) async throws -> String {
        let raw: String
        if c.baseURL == Self.inProcess, let local = localModel {
            raw = try await local.complete(messages: request.messages, temperature: request.temperature, maxTokens: request.maxTokens)
        } else if c.backend == .novaGateway, health.usesGatewayNative(c.baseURL) {
            raw = try await sendGatewayNative(c, request)
        } else {
            do {
                let (data, _) = try await NovaAIHTTP.data(session, try chatRequest(c, request, stream: false))
                guard let t = NovaAIWire.replyText(data) else { throw NovaAIError.badResponse }
                raw = t
            } catch NovaAIError.httpStatus(let code) where c.backend == .novaGateway && (code == 404 || code == 405) {
                // Gateway V2 has no OpenAI path: remember and use its own /api/chat.
                health.setGatewayNative(c.baseURL)
                raw = try await sendGatewayNative(c, request)
            }
        }
        return try finish(raw, format: request.format)
    }

    func sendGatewayNative(_ c: NovaAICandidate, _ request: NovaAIRequest) async throws -> String {
        guard let base = NovaAIWire.baseURL(c.baseURL), let url = URL(string: base.absoluteString + "/api/chat") else {
            throw NovaAIError.invalidURL(c.baseURL)
        }
        let body = NovaAIWire.gatewayNativeBody(request, appID: configuration.appID, maxInput: configuration.maxInputCharacters)
        let req = try NovaAIWire.post(url, body: body, headers: [:], timeout: timeout(request))
        let (data, _) = try await NovaAIHTTP.data(session, req)
        guard let t = NovaAIWire.replyText(data) else { throw NovaAIError.badResponse }
        return t
    }

    /// Reasoning removed, capped; JSON formats cut to the JSON payload.
    func finish(_ raw: String, format: NovaAIResponseFormat) throws -> String {
        guard let text = NovaAIText.clean(raw, max: configuration.maxOutputCharacters) else { throw NovaAIError.emptyResponse }
        if format.wantsJSON {
            guard let json = NovaAIText.jsonPayload(text) else { throw NovaAIError.emptyResponse }
            return json
        }
        return text
    }

    func timeout(_ request: NovaAIRequest) -> TimeInterval {
        min(max(request.timeout ?? settings.timeout, NovaAISettings.timeoutRange.lowerBound), NovaAISettings.timeoutRange.upperBound)
    }

    /// The chat request for a candidate. Enforces: http(s) URL with a host; a key only over https (or loopback
    /// for optional-key backends); keyed backends never without a key.
    public func chatRequest(_ c: NovaAICandidate, _ request: NovaAIRequest, stream: Bool) throws -> URLRequest {
        guard let base = NovaAIWire.baseURL(c.baseURL), let url = URL(string: base.absoluteString + c.backend.chatPath) else {
            throw NovaAIError.invalidURL(c.baseURL)
        }
        guard !c.model.isEmpty, c.model.count <= NovaAISettings.maxModelLength else { throw NovaAIError.invalidURL(c.model) }
        let headers = try authHeaders(c.backend, url: base)
        let maxInput = configuration.maxInputCharacters
        let body = c.backend.speaksOllama
            ? NovaAIWire.ollamaBody(request, model: c.model, stream: stream, maxInput: maxInput)
            : NovaAIWire.openAIBody(request, backend: c.backend, model: c.model, stream: stream, maxInput: maxInput)
        return try NovaAIWire.post(url, body: body, headers: headers, timeout: timeout(request))
    }

    /// Key headers for `backend` at `url`, or none. Throws before anything is sent when a key would travel insecurely.
    func authHeaders(_ backend: NovaAIBackend, url: URL) throws -> [String: String] {
        guard backend.acceptsKey else { return [:] }
        guard let key = keys.key(for: backend) else {
            if backend.requiresKey { throw NovaAIError.missingKey(backend) }
            return [:]
        }
        guard NovaAIWire.keyAllowed(url, backend: backend) else { throw NovaAIError.insecureTransport(url.host ?? "?") }
        return NovaAIWire.authHeaders(backend, key: key, configuration: configuration)
    }

    // MARK: - Stream

    /// Streamed answer: `.delta` events, then `.finished`. Fails over until the first text arrives; after that an
    /// error ends the stream. Backends without streaming (Nova Gateway's own API, a local model) send one delta.
    public func stream(_ request: NovaAIRequest) -> AsyncThrowingStream<NovaAIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStream(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func runStream(_ request: NovaAIRequest, emit: @Sendable (NovaAIStreamEvent) -> Void) async throws {
        let list = try liveCandidates(for: request)
        var attempts = 0
        var lastError: Error = NovaAIError.noBackendAvailable
        for c in list {
            var emitted = false
            for attempt in 1...configuration.retry.maxAttempts {
                try Task.checkCancellation()
                attempts += 1
                let started = Date()
                do {
                    let text = try await streamOne(c, request) { delta in emitted = true; emit(.delta(delta)) }
                    if c.baseURL != Self.inProcess { health.mark(c.baseURL, ok: true) }
                    emit(.finished(NovaAIResponse(text: text, backend: c.backend, model: c.model, endpoint: c.baseURL,
                                                  latency: Date().timeIntervalSince(started), attempts: attempts)))
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if emitted { throw error }          // text already shown: can't silently switch servers
                    lastError = error
                    if attempt < configuration.retry.maxAttempts, NovaAIRetry.isRetryable(error) {
                        await sleep(configuration.retry.delay(afterAttempt: attempt))
                        continue
                    }
                    if NovaAIRetry.isUnreachable(error), c.baseURL != Self.inProcess { health.mark(c.baseURL, ok: false) }
                    break
                }
            }
        }
        if list.count == 1 { throw lastError }
        throw NovaAIError.allBackendsFailed((lastError as? LocalizedError)?.errorDescription ?? "\(lastError)")
    }

    /// Streams one candidate; returns the whole cleaned text.
    func streamOne(_ c: NovaAICandidate, _ request: NovaAIRequest, delta: (String) -> Void) async throws -> String {
        let nonStreaming = c.baseURL == Self.inProcess || (c.backend == .novaGateway && health.usesGatewayNative(c.baseURL))
        if nonStreaming {
            let text = try await send(c, request)
            delta(text)
            return text
        }
        var filter = NovaAIThinkFilter()
        var raw = ""
        var visible = ""
        let cap = configuration.maxOutputCharacters
        do {
            try await NovaAIHTTP.lines(session, try chatRequest(c, request, stream: true)) { line in
                switch NovaAIWire.streamLine(line) {
                case .ignore: return false
                case .done: return true
                case .text(let t):
                    raw += t
                    var shown = filter.feed(t)
                    if visible.isEmpty { shown = String(shown.drop { $0.isWhitespace || $0.isNewline }) }
                    if visible.count + shown.count > cap { shown = String(shown.prefix(max(0, cap - visible.count))) }
                    if !shown.isEmpty { visible += shown; delta(shown) }
                    return visible.count >= cap
                }
            }
        } catch NovaAIError.httpStatus(let code) where c.backend == .novaGateway && (code == 404 || code == 405) {
            health.setGatewayNative(c.baseURL)
            let text = try await send(c, request)
            delta(text)
            return text
        }
        let tail = filter.finish()
        if !tail.isEmpty, visible.count < cap { visible += tail; delta(tail) }
        return try finish(raw, format: request.format)
    }

    // MARK: - Models and probes

    /// GET request for a backend's model list (also its probe), or a thrown reason (bad URL, insecure key).
    func modelsRequest(_ backend: NovaAIBackend, baseURL: String) throws -> URLRequest {
        guard backend != .auto, let base = NovaAIWire.baseURL(baseURL),
              let url = URL(string: base.absoluteString + backend.modelsPath) else { throw NovaAIError.invalidURL(baseURL) }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: configuration.probeTimeout)
        for (k, v) in try authHeaders(backend, url: base) { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    /// Models the backend offers (for the picker). Falls back to `backend.fallbackModels` when it can't list them.
    public func listModels(_ backend: NovaAIBackend) async -> [String] {
        guard backend != .auto else { return [] }
        if backend == .mlx, localModel != nil { return [settings.model(for: .mlx)] }
        guard let req = try? modelsRequest(backend, baseURL: settings.url(for: backend)),
              case let (data, _)? = try? await NovaAIHTTP.data(session, req) else { return backend.fallbackModels }
        var seen = Set<String>()
        let names = NovaAIWire.modelNames(data).filter { !$0.isEmpty && $0.count <= NovaAISettings.maxModelLength && seen.insert($0).inserted }
        return names.isEmpty ? backend.fallbackModels : Array(names.sorted().prefix(1000))
    }

    /// Is `backend` reachable? Local servers count as up on any reply below 500; keyed backends must answer 2xx
    /// (the key works). Ollama is up if any configured server is.
    public func probe(_ backend: NovaAIBackend) async -> NovaAIProbe {
        guard backend != .auto else { return NovaAIProbe(backend: backend, reachable: false, detail: "not a backend") }
        if backend == .mlx, let local = localModel {
            let ok = await local.isAvailable()
            return NovaAIProbe(backend: backend, reachable: ok, baseURL: Self.inProcess, detail: ok ? "in-process model ready" : "in-process model unavailable")
        }
        if backend.requiresKey, !keys.hasKey(for: backend) {
            return NovaAIProbe(backend: backend, reachable: false, baseURL: settings.url(for: backend), detail: "no API key")
        }
        var urls = [settings.url(for: backend)]
        if backend == .ollama { urls += settings.extraOllamaEndpoints.map { NovaAISettings(urls: ["ollama": $0.url]).url(for: .ollama) } }
        var last = NovaAIProbe(backend: backend, reachable: false, detail: "not configured")
        for u in urls {
            let started = Date()
            do {
                let req = try modelsRequest(backend, baseURL: u)
                let (_, code) = try await NovaAIHTTP.status(session, req)
                let ok = backend.requiresKey ? (200...299).contains(code) : (code > 0 && code < 500)
                health.mark(u, ok: ok)
                last = NovaAIProbe(backend: backend, reachable: ok, baseURL: u, latency: Date().timeIntervalSince(started), detail: "HTTP \(code)")
                if ok { return last }
            } catch {
                health.mark(u, ok: false)
                last = NovaAIProbe(backend: backend, reachable: false, baseURL: u, detail: Self.describe(error))
            }
        }
        return last
    }

    /// Probes every backend in the chain concurrently.
    public func probeAll() async -> [NovaAIBackend: NovaAIProbe] {
        await withTaskGroup(of: NovaAIProbe.self) { group in
            for b in chain() { group.addTask { await self.probe(b) } }
            var out: [NovaAIBackend: NovaAIProbe] = [:]
            for await p in group { out[p.backend] = p }
            return out
        }
    }

    /// Short, key-free error text for status displays.
    public static func describe(_ error: Error) -> String {
        if let e = error as? NovaAIError { return e.errorDescription ?? "\(e)" }
        if let u = error as? URLError {
            switch u.code {
            case .cannotConnectToHost: return "connection refused"
            case .cannotFindHost, .dnsLookupFailed: return "host not found"
            case .notConnectedToInternet: return "offline"
            case .timedOut: return "timed out"
            case .secureConnectionFailed, .serverCertificateUntrusted: return "TLS failed"
            default: return "network error \(u.code.rawValue)"
            }
        }
        if error is CancellationError { return "cancelled" }
        return (error as? LocalizedError)?.errorDescription ?? "error"
    }
}
