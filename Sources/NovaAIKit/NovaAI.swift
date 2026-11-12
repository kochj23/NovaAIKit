//
//  NovaAI.swift
//  NovaAIKit
//
//  The one object an app talks to. Owns the persisted settings (on/off, backend, models, URLs), the keys
//  (Keychain only), the observable status, and the app-level contract from CarTest/StuntDriver:
//    • AI off → nothing is sent; callers get their fallback.
//    • `generate(_:validate:fallback:)` never throws and never blocks: AI answer, validated (one retry with the
//      validator's complaint), else the app's scripted fallback.
//  Network work runs off the main actor in `NovaAIEngine`.
//
//  Copyright © 2026 Jordan Koch.
//

import Foundation
import Combine

/// Observable AI status: active backend, reachability, last error, latency, where the last answer came from.
public struct NovaAIStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// AI switched off: built-in answers only.
        case off
        /// Not checked yet.
        case unknown
        case checking
        /// A backend answered (last call or probe).
        case online
        /// Nothing answered: fallbacks are used.
        case offline
    }

    public var state: State = .unknown
    /// The backend that answered last (or the first reachable one in the last probe).
    public var activeBackend: NovaAIBackend?
    public var activeModel: String?
    public var host: String?
    /// Last probe per backend.
    public var reachability: [NovaAIBackend: Bool] = [:]
    /// Last failure, key-free.
    public var lastError: String?
    /// Latency of the last successful answer or probe.
    public var lastLatency: TimeInterval?
    /// Where the last value handed to the app came from.
    public var lastSource: NovaAISource?
    public var updatedAt: Date?

    public init() {}

    public var isReachable: Bool { state == .online }

    /// "Ollama (localhost) · online · 420 ms", "AI off · built-in answers", …
    public var label: String {
        switch state {
        case .off: return "AI off · built-in answers"
        case .unknown: return "AI not checked yet"
        case .checking: return "Checking AI…"
        case .offline: return "AI offline · built-in answers"
        case .online:
            var s = activeBackend?.displayName ?? "AI"
            if let host { s += " (\(host))" }
            s += " · online"
            if let ms = lastLatency.map({ Int(($0 * 1000).rounded()) }) { s += " · \(ms) ms" }
            return s
        }
    }
}

@MainActor
public final class NovaAI: ObservableObject {
    public let configuration: NovaAIConfiguration
    /// The user's settings; every change is saved.
    @Published public var settings: NovaAISettings {
        didSet {
            guard settings != oldValue else { return }
            storage.save(settings)
            if !settings.enabled { status.state = .off; status.activeBackend = nil }
            else if !oldValue.enabled || settings.backend != oldValue.backend || settings.allowNova != oldValue.allowNova {
                status.state = .unknown
            }
        }
    }
    @Published public private(set) var status = NovaAIStatus()
    /// Bumped when a key is stored or removed (so views showing `hasAPIKey` refresh).
    @Published public private(set) var keysVersion = 0

    public let keys: NovaAIKeys
    public let health: NovaAIHealth
    private let storage: any NovaAISettingsStorage
    private let session: URLSession
    private let sleep: NovaAISleeper
    public var localModel: (any NovaAILocalModel)?

    /// - Parameters:
    ///   - configuration: the app's id/name (Keychain services `com.jkoch.<appID>.<backend>`), defaults, retry policy.
    ///   - storage: where settings persist (default: UserDefaults key `NovaAIKit.settings`).
    ///   - keyStore: secrets (default: the Keychain). Tests pass `NovaAIMemoryKeyStore`.
    ///   - session: URLSession (tests pass one with a stub `URLProtocol`).
    ///   - localModel: an in-process engine for the `mlx` backend (optional).
    public init(configuration: NovaAIConfiguration,
                storage: (any NovaAISettingsStorage)? = nil,
                keyStore: (any NovaAIKeyStore)? = nil,
                session: URLSession = .shared,
                sleep: @escaping NovaAISleeper = NovaAIRetry.taskSleep,
                localModel: (any NovaAILocalModel)? = nil) {
        self.configuration = configuration
        let storage = storage ?? NovaAIUserDefaultsStorage()
        self.storage = storage
        self.keys = NovaAIKeys(configuration: configuration, store: keyStore)
        self.health = NovaAIHealth(ttl: configuration.healthTTL)
        self.session = session
        self.sleep = sleep
        self.localModel = localModel
        let loaded = storage.load() ?? configuration.defaultSettings
        self.settings = loaded
        if !loaded.enabled { status.state = .off }
    }

    /// AI on/off (persisted).
    public var isEnabled: Bool {
        get { settings.enabled }
        set { settings.enabled = newValue }
    }

    /// "No Nova" switch (persisted). See `NovaAISettings.allowNova`.
    public var allowNova: Bool {
        get { settings.allowNova }
        set { settings.allowNova = newValue }
    }

    /// Concrete backends usable on this platform with the current settings (Auto's order; no Nova Gateway when
    /// `allowNova` is off). What the pickers offer.
    public var availableBackends: [NovaAIBackend] {
        NovaAIBackend.autoOrder.filter { settings.allowNova || $0 != .novaGateway }
    }

    /// A snapshot engine for the current settings (safe to use off the main actor).
    public var engine: NovaAIEngine {
        NovaAIEngine(configuration: configuration, settings: settings, keys: keys, session: session,
                     health: health, sleep: sleep, localModel: localModel)
    }

    // MARK: - Keys

    public func hasAPIKey(for backend: NovaAIBackend) -> Bool { keys.hasKey(for: backend) }

    /// Store (non-empty) or remove (nil/empty) a key. Keychain only.
    @discardableResult
    public func setAPIKey(_ key: String?, for backend: NovaAIBackend) -> Bool {
        let ok = keys.setKey(key, for: backend)
        keysVersion += 1
        return ok
    }

    /// See `NovaAIKeys.migrateLegacyKey`.
    @discardableResult
    public func migrateLegacyKey(service: String, account: String, to backend: NovaAIBackend, deleteLegacy: Bool = false,
                                 legacyStore: (any NovaAIKeyStore)? = nil) -> NovaAIKeyMigrationResult {
        let r = keys.migrateLegacyKey(service: service, account: account, to: backend, deleteLegacy: deleteLegacy, legacyStore: legacyStore)
        if r == .migrated { keysVersion += 1 }
        return r
    }

    /// See `NovaAIKeys.migrateLegacyDefaultsKey`.
    @discardableResult
    public func migrateLegacyDefaultsKey(_ key: String, defaults: UserDefaults = .standard, to backend: NovaAIBackend) -> NovaAIKeyMigrationResult {
        let r = keys.migrateLegacyDefaultsKey(key, defaults: defaults, to: backend)
        if r == .migrated { keysVersion += 1 }
        return r
    }

    /// Once per install: import the old `AIBackendManager` UserDefaults settings (URLs, backend, Ollama model,
    /// on/off) if this app never saved NovaAIKit settings. Returns true when something was imported.
    @discardableResult
    public func migrateLegacySettings(from defaults: UserDefaults = .standard, markerKey: String = "NovaAIKit.legacySettingsMigrated") -> Bool {
        guard !defaults.bool(forKey: markerKey) else { return false }
        defaults.set(true, forKey: markerKey)
        guard storage.load() == nil || settings == configuration.defaultSettings,
              let s = NovaAILegacySettings.read(from: defaults, base: settings) else { return false }
        settings = s
        return true
    }

    /// What `migrateFromLegacyAIBackendManager` did.
    public struct LegacyMigrationReport: Sendable, Equatable {
        public var settingsImported = false
        /// Old UserDefaults key → result of moving it to the Keychain.
        public var keys: [String: NovaAIKeyMigrationResult] = [:]
        /// Obsolete UserDefaults keys that were deleted.
        public var removedKeys: [String] = []
    }

    /// One call for apps that used the copy-pasted `AIBackendManager`: imports its settings once, moves a plaintext
    /// OpenAI key from UserDefaults into the Keychain (defaults entry removed only after a verified write), and
    /// deletes the obsolete keys (removed backends' secrets, the guardian prompt log, usage stats). Idempotent.
    @discardableResult
    public func migrateFromLegacyAIBackendManager(defaults: UserDefaults = .standard) -> LegacyMigrationReport {
        var report = LegacyMigrationReport()
        report.settingsImported = migrateLegacySettings(from: defaults)
        for key in NovaAILegacySettings.openAIKeyKeys where defaults.object(forKey: key) != nil {
            report.keys[key] = migrateLegacyDefaultsKey(key, defaults: defaults, to: .openAI)
        }
        report.removedKeys = NovaAILegacySettings.removeObsoleteKeys(from: defaults)
        return report
    }

    // MARK: - Throwing API

    /// One answer (failover + retries). Throws `NovaAIError.disabled` when AI is off.
    public func complete(_ request: NovaAIRequest) async throws -> NovaAIResponse {
        guard settings.enabled else { status.state = .off; throw NovaAIError.disabled }
        let engine = self.engine
        do {
            let r = try await engine.complete(request)
            recordSuccess(r)
            return r
        } catch {
            if !(error is CancellationError) { recordFailure(error) }
            throw error
        }
    }

    /// Drop-in for the old `AIBackendManager.shared.generate(prompt:systemPrompt:temperature:maxTokens:)`.
    public func generate(prompt: String, systemPrompt: String? = nil, temperature: Double = 0.7, maxTokens: Int = 1024) async throws -> String {
        try await complete(NovaAIRequest(prompt: prompt, system: systemPrompt, temperature: temperature, maxTokens: maxTokens)).text
    }

    /// Multi-turn chat: the conversation so far → the assistant's reply.
    public func chat(_ messages: [NovaAIMessage], temperature: Double = 0.7, maxTokens: Int = 1024) async throws -> String {
        try await complete(NovaAIRequest(messages: messages, temperature: temperature, maxTokens: maxTokens)).text
    }

    /// Streamed text deltas. Throws `NovaAIError.disabled` (as the stream's error) when AI is off.
    public func stream(_ request: NovaAIRequest) -> AsyncThrowingStream<String, Error> {
        let enabled = settings.enabled
        let events = engine.stream(request)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard enabled else {
                    self?.status.state = .off
                    continuation.finish(throwing: NovaAIError.disabled)
                    return
                }
                do {
                    for try await e in events {
                        switch e {
                        case .delta(let d): continuation.yield(d)
                        case .finished(let r): self?.recordSuccess(r)
                        }
                    }
                    continuation.finish()
                } catch {
                    if !(error is CancellationError) { self?.recordFailure(error) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streamed events including the final `NovaAIResponse` (does not update `status`).
    public func streamEvents(_ request: NovaAIRequest) -> AsyncThrowingStream<NovaAIStreamEvent, Error> {
        guard settings.enabled else {
            return AsyncThrowingStream { $0.finish(throwing: NovaAIError.disabled) }
        }
        return engine.stream(request)
    }

    // MARK: - Never-throwing API (toggle + validation + fallback)

    /// AI value or the app's fallback — never throws, never hangs past the timeouts.
    ///  1. AI off → `fallback()` (nothing sent).
    ///  2. Ask (Auto failover, retries). Failure → `fallback()`.
    ///  3. `validate` the reply (reject by throwing; clamp by returning a corrected value).
    ///     Rejected → ask once more with the complaint appended; rejected again → `fallback()`.
    public func generate<Value: Sendable>(_ request: NovaAIRequest,
                                          validate: @escaping @Sendable (String) throws -> Value,
                                          fallback: @escaping @Sendable () -> Value) async -> NovaAIResult<Value> {
        guard settings.enabled else {
            status.state = .off
            return deliver(NovaAIResult(value: fallback(), source: .fallback(.disabled)))
        }
        let first: NovaAIResponse
        do { first = try await complete(request) } catch {
            return deliver(NovaAIResult(value: fallback(), source: .fallback(.unavailable(NovaAIEngine.describe(error)))))
        }
        let complaint: String
        do {
            return deliver(NovaAIResult(value: try validate(first.text), source: .ai(backend: first.backend, model: first.model), response: first))
        } catch {
            complaint = Self.reason(error)
        }
        var retry = request
        retry.messages += [.assistant(String(first.text.prefix(4000))),
                           .user("Your previous reply was rejected: \(complaint). Reply again, following every instruction exactly.")]
        retry.backend = first.backend          // same backend that answered
        if let second = try? await complete(retry) {
            do {
                return deliver(NovaAIResult(value: try validate(second.text), source: .ai(backend: second.backend, model: second.model), response: second))
            } catch {
                let why = Self.reason(error)
                status.lastError = "Reply rejected: \(why)"
                return deliver(NovaAIResult(value: fallback(), source: .fallback(.validationFailed(why))))
            }
        }
        status.lastError = "Reply rejected: \(complaint)"
        return deliver(NovaAIResult(value: fallback(), source: .fallback(.validationFailed(complaint))))
    }

    /// Text with the never-throwing contract. Default validator: non-empty after trimming.
    public func text(_ request: NovaAIRequest,
                     validate: @escaping @Sendable (String) throws -> String = NovaAI.nonEmpty,
                     fallback: @escaping @Sendable () -> String) async -> NovaAIResult<String> {
        await generate(request, validate: validate, fallback: fallback)
    }

    /// Structured output: asks for JSON (schema-constrained where the backend supports it), decodes `T`, then runs
    /// `validate` (reject by throwing, clamp by returning a fixed value). Never throws.
    public func structured<T: Decodable & Sendable>(_ type: T.Type, _ request: NovaAIRequest,
                                                    schema: NovaAIJSONSchema? = nil,
                                                    validate: @escaping @Sendable (T) throws -> T = { $0 },
                                                    fallback: @escaping @Sendable () -> T) async -> NovaAIResult<T> {
        var req = request
        req.format = schema.map { .jsonSchema($0) } ?? .json
        return await generate(req, validate: { text in try validate(try NovaAIText.decode(T.self, from: text)) }, fallback: fallback)
    }

    /// Default text validator: rejects empty replies.
    public nonisolated static let nonEmpty: @Sendable (String) throws -> String = { s in
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { throw NovaAIValidationError("empty reply") }
        return t
    }

    nonisolated static func reason(_ error: Error) -> String {
        String(((error as? LocalizedError)?.errorDescription ?? "\(error)").prefix(300))
    }

    private func deliver<V>(_ r: NovaAIResult<V>) -> NovaAIResult<V> {
        status.lastSource = r.source
        return r
    }

    // MARK: - Status, models, test connection

    /// Probe the configured backends (Auto: all, concurrently); the active backend is the first reachable in order.
    public func refreshStatus() async {
        guard settings.enabled else { status.state = .off; status.activeBackend = nil; return }
        status.state = .checking
        let engine = self.engine
        let probes = await engine.probeAll()
        status.reachability = probes.mapValues(\.reachable)
        status.updatedAt = Date()
        if let b = engine.chain().first(where: { probes[$0]?.reachable == true }), let p = probes[b] {
            status.state = .online
            status.activeBackend = b
            status.activeModel = settings.model(for: b)
            status.host = p.baseURL.flatMap { URL(string: $0)?.host }
            status.lastLatency = p.latency
            status.lastError = nil
        } else {
            status.state = .offline
            status.activeBackend = nil
            status.lastError = engine.chain().compactMap { b in probes[b].map { "\(b.displayName): \($0.detail)" } }.first
        }
    }

    /// Probe one backend (the settings screen's "Test connection").
    public func testConnection(_ backend: NovaAIBackend? = nil) async -> NovaAIProbe {
        let b = backend ?? settings.backend
        if b == .auto {
            await refreshStatus()
            if let a = status.activeBackend { return NovaAIProbe(backend: a, reachable: true, latency: status.lastLatency, detail: "Auto → \(a.displayName)") }
            return NovaAIProbe(backend: .auto, reachable: false, detail: status.lastError ?? "nothing reachable")
        }
        let p = await engine.probe(b)
        status.reachability[b] = p.reachable
        return p
    }

    /// Models the backend offers (picker); never throws.
    public func listModels(for backend: NovaAIBackend) async -> [String] {
        await engine.listModels(backend)
    }

    // MARK: - Recording

    private func recordSuccess(_ r: NovaAIResponse) {
        status.state = .online
        status.activeBackend = r.backend
        status.activeModel = r.model
        status.host = r.host
        status.lastLatency = r.latency
        status.lastError = nil
        status.reachability[r.backend] = true
        status.updatedAt = Date()
    }

    private func recordFailure(_ error: Error) {
        if case NovaAIError.disabled = error { status.state = .off; return }
        status.state = .offline
        status.activeBackend = nil
        status.lastError = NovaAIEngine.describe(error)
        status.updatedAt = Date()
    }
}
