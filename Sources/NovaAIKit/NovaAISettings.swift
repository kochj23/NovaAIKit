//
//  NovaAISettings.swift
//  NovaAIKit
//
//  The user's AI settings (no secrets — keys live only in the Keychain), the app's fixed configuration, and
//  pluggable persistence. Settings decode tolerantly: unknown or bad values fall back to defaults.
//
//  Copyright © 2026 Jordan Koch.
//

import Foundation

/// An extra Ollama-compatible server (e.g. a LAN host, the fleet router), tried after the primary Ollama URL.
public struct NovaAIEndpoint: Codable, Sendable, Hashable {
    public var url: String
    public var model: String
    public init(url: String, model: String) {
        self.url = url
        self.model = model
    }
}

/// Per-app user settings. Persisted as one JSON blob by a `NovaAISettingsStorage`.
public struct NovaAISettings: Codable, Sendable, Equatable {
    /// Off: no request is ever sent; every caller gets its fallback.
    public var enabled: Bool = true
    /// The chosen backend; `.auto` walks `NovaAIBackend.autoOrder`.
    public var backend: NovaAIBackend = .auto
    /// Base URL per backend (raw value → URL). Missing: `NovaAIBackend.defaultURL`.
    public var urls: [String: String] = [:]
    /// Model per backend (raw value → model). Missing: `NovaAIBackend.defaultModel`.
    public var models: [String: String] = [:]
    /// Extra Ollama-compatible servers, tried in order after the primary Ollama URL.
    public var extraOllamaEndpoints: [NovaAIEndpoint] = []
    /// Seconds per attempt before failing over (clamped 2…600).
    public var timeout: TimeInterval = 60

    public static let maxURLLength = 300
    public static let maxModelLength = 200
    public static let timeoutRange: ClosedRange<TimeInterval> = 2...600

    public init(enabled: Bool = true, backend: NovaAIBackend = .auto, urls: [String: String] = [:],
                models: [String: String] = [:], extraOllamaEndpoints: [NovaAIEndpoint] = [], timeout: TimeInterval = 60) {
        self.enabled = enabled
        self.backend = backend
        self.urls = Self.clean(urls, max: Self.maxURLLength)
        self.models = Self.clean(models, max: Self.maxModelLength)
        self.extraOllamaEndpoints = extraOllamaEndpoints
        self.timeout = min(max(timeout, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
    }

    enum CodingKeys: String, CodingKey { case enabled, backend, urls, models, extraOllamaEndpoints, timeout }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NovaAISettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        let raw = (try? c.decodeIfPresent(String.self, forKey: .backend)) ?? nil
        backend = raw.flatMap(NovaAIBackend.init(legacyName:)).flatMap { $0.isSupportedOnThisPlatform ? $0 : nil } ?? d.backend
        urls = Self.clean((try? c.decodeIfPresent([String: String].self, forKey: .urls)) ?? nil, max: Self.maxURLLength)
        models = Self.clean((try? c.decodeIfPresent([String: String].self, forKey: .models)) ?? nil, max: Self.maxModelLength)
        extraOllamaEndpoints = ((try? c.decodeIfPresent([NovaAIEndpoint].self, forKey: .extraOllamaEndpoints)) ?? nil) ?? []
        let t = ((try? c.decodeIfPresent(Double.self, forKey: .timeout)) ?? nil) ?? d.timeout
        timeout = min(max(t.isFinite ? t : d.timeout, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
    }

    /// Only known, concrete backends with non-empty values within the length cap.
    static func clean(_ d: [String: String]?, max: Int) -> [String: String] {
        (d ?? [:]).filter { key, value in
            guard let b = NovaAIBackend(rawValue: key), b != .auto else { return false }
            return !value.isEmpty && value.count <= max
        }
    }

    /// The base URL for `backend` (trailing slashes removed).
    public func url(for backend: NovaAIBackend) -> String {
        var s = (urls[backend.rawValue] ?? backend.defaultURL).trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// The model for `backend`.
    public func model(for backend: NovaAIBackend) -> String { models[backend.rawValue] ?? backend.defaultModel }

    /// Set a base URL; the default (or empty) clears the override.
    public mutating func setURL(_ value: String, for backend: NovaAIBackend) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        urls[backend.rawValue] = (v.isEmpty || v == backend.defaultURL || backend == .auto) ? nil : String(v.prefix(Self.maxURLLength))
    }

    /// Set a model; the default (or empty) clears the override.
    public mutating func setModel(_ value: String, for backend: NovaAIBackend) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        models[backend.rawValue] = (v.isEmpty || v == backend.defaultModel || backend == .auto) ? nil : String(v.prefix(Self.maxModelLength))
    }
}

// MARK: - App configuration

/// Fixed, per-app facts. Created once in the app; never user-editable.
public struct NovaAIConfiguration: Sendable {
    /// Lowercase app id used in Keychain services (`com.jkoch.<appID>.<backend>`) and the gateway session id.
    public var appID: String
    /// Shown to OpenRouter as `X-Title`.
    public var appName: String
    /// Sent to OpenRouter as `HTTP-Referer`.
    public var appURL: String
    /// Data Protection keychain access group (signed apps that want no prompts after rebuilds). nil: login keychain.
    public var keychainAccessGroup: String?
    /// The settings a fresh install starts with (e.g. LAN Ollama endpoints, a different default backend).
    public var defaultSettings: NovaAISettings
    /// Retries per backend before failing over.
    public var retry: NovaAIRetryPolicy
    /// Timeout for reachability probes and model listing.
    public var probeTimeout: TimeInterval
    /// How long a backend that failed is skipped by Auto.
    public var healthTTL: TimeInterval
    /// Prompt text beyond this many characters per message is cut.
    public var maxInputCharacters: Int
    /// Replies are cut to this many characters.
    public var maxOutputCharacters: Int

    public init(appID: String, appName: String, appURL: String? = nil, keychainAccessGroup: String? = nil,
                defaultSettings: NovaAISettings = NovaAISettings(), retry: NovaAIRetryPolicy = .network,
                probeTimeout: TimeInterval = 3, healthTTL: TimeInterval = 60,
                maxInputCharacters: Int = 100_000, maxOutputCharacters: Int = 32_000) {
        self.appID = Self.normalizedID(appID)
        self.appName = appName
        self.appURL = appURL ?? "https://github.com/kochj23/\(appName.replacingOccurrences(of: " ", with: ""))"
        self.keychainAccessGroup = keychainAccessGroup
        self.defaultSettings = defaultSettings
        self.retry = retry
        self.probeTimeout = probeTimeout
        self.healthTTL = healthTTL
        self.maxInputCharacters = max(1, maxInputCharacters)
        self.maxOutputCharacters = max(1, maxOutputCharacters)
    }

    /// Lowercase letters, digits, `.` and `-` only ("Mail Summary" → "mailsummary").
    public static func normalizedID(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        let id = s.lowercased().filter { allowed.contains($0) }
        return id.isEmpty ? "app" : id
    }

    /// The Keychain service for a backend's API key: `com.jkoch.<appID>.<backend>`.
    public func keychainService(for backend: NovaAIBackend) -> String { "com.jkoch.\(appID).\(backend.rawValue)" }

    /// The Keychain account every NovaAIKit key uses.
    public static let keychainAccount = "apiKey"
}

// MARK: - Persistence

/// Where settings live. Settings never contain secrets, so UserDefaults is fine; apps with their own store
/// (a database, a shared file) implement this.
public protocol NovaAISettingsStorage: Sendable {
    func load() -> NovaAISettings?
    func save(_ settings: NovaAISettings)
}

/// One JSON blob in UserDefaults (default key `NovaAIKit.settings`).
public struct NovaAIUserDefaultsStorage: NovaAISettingsStorage {
    public var suiteName: String?
    public var key: String

    public init(suiteName: String? = nil, key: String = "NovaAIKit.settings") {
        self.suiteName = suiteName
        self.key = key
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> NovaAISettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(NovaAISettings.self, from: data)
    }

    public func save(_ settings: NovaAISettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }
}

/// Settings kept in memory only (tests, previews, CLIs).
public final class NovaAIMemoryStorage: NovaAISettingsStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: NovaAISettings?
    public init(_ initial: NovaAISettings? = nil) { value = initial }
    public func load() -> NovaAISettings? { lock.lock(); defer { lock.unlock() }; return value }
    public func save(_ settings: NovaAISettings) { lock.lock(); value = settings; lock.unlock() }
}

// MARK: - Legacy settings migration

/// Reads the UserDefaults keys the old copy-pasted `AIBackendManager` wrote, once, into `NovaAISettings`.
/// API keys are NOT read here — use `NovaAI.migrateLegacyDefaultsKey` so they go to the Keychain.
public enum NovaAILegacySettings {
    /// Old key → backend whose URL it held.
    public static let urlKeys: [String: NovaAIBackend] = [
        "AIBackend_OllamaURL": .ollama, "AIBackend_TinyLLMURL": .tinyLLM, "AIBackend_TinyChatURL": .tinyChat,
        "AIBackend_OpenWebUIURL": .openWebUI, "AIBackend_NovaGatewayURL": .novaGateway, "AIBackend_MLXURL": .mlx,
        "AIBackendManager_OllamaURL": .ollama, "AIBackendManager_TinyLLMURL": .tinyLLM,
        "AIBackendManager_TinyChatURL": .tinyChat, "AIBackendManager_OpenWebUIURL": .openWebUI,
    ]
    /// Old keys that held the chosen backend (display names or ids).
    public static let backendKeys = ["AIBackend_Active", "AIBackendManager_SelectedBackend", "selectedAIBackend", "AIBackend_Selected"]
    /// Old keys that held the Ollama model.
    public static let ollamaModelKeys = ["AIBackend_OllamaModel", "AIBackendManager_OllamaModel", "selectedOllamaModel",
                                         "ollamaModel", "ollamaLLMModel"]
    /// Old keys that held the plaintext OpenAI key (move with `migrateLegacyDefaultsKey(_:to: .openAI)`).
    public static let openAIKeyKeys = ["AIBackend_OpenAI_Key", "OpenAIAPIKey"]
    /// Old keys with no successor: secrets of the removed Google/Azure/AWS/IBM backends (plaintext), the
    /// EthicalAIGuardian prompt log and block flag, usage stats. `removeObsoleteKeys` deletes them.
    public static let obsoleteKeys = [
        "AIBackend_GoogleCloud_Key", "AIBackend_Azure_Key", "AIBackend_Azure_Endpoint", "AIBackend_AWS_AccessKey",
        "AIBackend_AWS_SecretKey", "AIBackend_AWS_Region", "AIBackend_IBM_Key", "AIBackend_IBM_URL",
        "AIGuardian_UsageLog", "AIGuardian_PermanentBlock", "AIBackend_UsageStats",
    ]

    /// Deletes `obsoleteKeys` from `defaults`. Returns the keys that were present.
    @discardableResult
    public static func removeObsoleteKeys(from defaults: UserDefaults) -> [String] {
        obsoleteKeys.filter { key in
            guard defaults.object(forKey: key) != nil else { return false }
            defaults.removeObject(forKey: key)
            return true
        }
    }
    /// Old keys that held the on/off switch.
    public static let enabledKeys = ["AIBackend_Enabled", "AIBackendManager_AIEnabled", "aiEnabled"]

    /// Settings built from `defaults` on top of `base`, or nil when no legacy key exists.
    public static func read(from defaults: UserDefaults, base: NovaAISettings) -> NovaAISettings? {
        var s = base
        var found = false
        for (key, backend) in urlKeys {
            if let v = defaults.string(forKey: key), !v.isEmpty { s.setURL(v, for: backend); found = true }
        }
        for key in backendKeys {
            if let v = defaults.string(forKey: key), let b = NovaAIBackend(legacyName: v), b.isSupportedOnThisPlatform {
                s.backend = b; found = true; break
            }
        }
        for key in ollamaModelKeys {
            if let v = defaults.string(forKey: key), !v.isEmpty { s.setModel(v, for: .ollama); found = true; break }
        }
        for key in enabledKeys where defaults.object(forKey: key) != nil {
            s.enabled = defaults.bool(forKey: key); found = true; break
        }
        return found ? s : nil
    }
}
