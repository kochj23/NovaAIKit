//
//  NovaAIModels.swift
//  NovaAIKit
//
//  Requests, responses, errors and the outcome types of the never-throwing API.
//
//  Copyright © 2026 Jordan Koch.
//

import Foundation

// MARK: - Messages and requests

/// One chat message.
public struct NovaAIMessage: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public var role: Role
    public var content: String

    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ s: String) -> NovaAIMessage { .init(.system, s) }
    public static func user(_ s: String) -> NovaAIMessage { .init(.user, s) }
    public static func assistant(_ s: String) -> NovaAIMessage { .init(.assistant, s) }
}

/// A JSON Schema for structured output, stored as JSON bytes so it stays `Sendable`.
public struct NovaAIJSONSchema: Sendable, Equatable {
    /// Schema name (OpenAI `json_schema.name`): letters, digits, `_` and `-`.
    public var name: String
    /// The schema document, UTF-8 JSON.
    public var json: Data

    /// - Throws: `NovaAIError.invalidSchema` when `json` isn't a JSON object.
    public init(name: String, json: String) throws {
        guard let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw NovaAIError.invalidSchema }
        self.name = Self.cleanName(name)
        self.json = data
    }

    /// - Throws: `NovaAIError.invalidSchema` when `object` can't be serialised.
    public init(name: String, object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            throw NovaAIError.invalidSchema
        }
        self.name = Self.cleanName(name)
        self.json = data
    }

    /// The schema as a Foundation object, for request bodies.
    var object: Any { (try? JSONSerialization.jsonObject(with: json)) ?? [String: Any]() }

    /// The schema as compact text, for backends that only get it in the prompt.
    var text: String { String(data: json, encoding: .utf8) ?? "{}" }

    static func cleanName(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let n = String(s.filter { allowed.contains($0) }.prefix(64))
        return n.isEmpty ? "response" : n
    }
}

/// What shape the reply must have.
public enum NovaAIResponseFormat: Sendable, Equatable {
    /// Free text.
    case text
    /// Any JSON object (Ollama `format: "json"`, OpenAI `json_object`); the kit cuts the reply to its `{…}`.
    case json
    /// A JSON object matching a schema (native where `supportsJSONSchema`, else via the prompt).
    case jsonSchema(NovaAIJSONSchema)

    var wantsJSON: Bool { self != .text }
}

/// One AI request. Build it with `init(prompt:system:)` or `init(messages:)`.
public struct NovaAIRequest: Sendable, Equatable {
    public var messages: [NovaAIMessage]
    public var temperature: Double
    public var maxTokens: Int
    public var format: NovaAIResponseFormat
    /// Use this backend only (no Auto failover). nil: the user's setting.
    public var backend: NovaAIBackend?
    /// Use this model on whichever backend answers. nil: the per-backend model from settings.
    public var model: String?
    /// Per-attempt timeout in seconds. nil: the settings value.
    public var timeout: TimeInterval?
    /// Let reasoning models think first (Ollama `think: true`). Off by default: thinking can use the whole token
    /// budget and leave an empty answer. `<think>` blocks are always stripped from replies.
    public var reasoning: Bool

    public init(messages: [NovaAIMessage], temperature: Double = 0.7, maxTokens: Int = 1024,
                format: NovaAIResponseFormat = .text, backend: NovaAIBackend? = nil, model: String? = nil,
                timeout: TimeInterval? = nil, reasoning: Bool = false) {
        self.reasoning = reasoning
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.format = format
        self.backend = backend
        self.model = model
        self.timeout = timeout
    }

    /// A single-turn request: optional system prompt, then the user prompt.
    public init(prompt: String, system: String? = nil, temperature: Double = 0.7, maxTokens: Int = 1024,
                format: NovaAIResponseFormat = .text) {
        var m: [NovaAIMessage] = []
        if let system, !system.isEmpty { m.append(.system(system)) }
        m.append(.user(prompt))
        self.init(messages: m, temperature: temperature, maxTokens: maxTokens, format: format)
    }
}

/// A successful answer.
public struct NovaAIResponse: Sendable, Equatable {
    public var text: String
    public var backend: NovaAIBackend
    public var model: String
    /// Base URL of the server that answered (never contains a key).
    public var endpoint: String
    /// Wall-clock time of the successful attempt.
    public var latency: TimeInterval
    /// Requests sent in total for this answer (retries and failover included).
    public var attempts: Int

    public init(text: String, backend: NovaAIBackend, model: String, endpoint: String, latency: TimeInterval, attempts: Int) {
        self.text = text
        self.backend = backend
        self.model = model
        self.endpoint = endpoint
        self.latency = latency
        self.attempts = attempts
    }

    public var host: String? { URL(string: endpoint)?.host }
}

// MARK: - Errors

/// Everything the throwing API can throw. Messages never contain keys or prompt text.
public enum NovaAIError: Error, Equatable, Sendable, LocalizedError {
    /// AI is switched off for this app. Nothing was sent.
    case disabled
    /// No backend is configured/usable (e.g. Auto with nothing reachable, a keyed backend without a key).
    case noBackendAvailable
    /// A URL that isn't http(s) with a host.
    case invalidURL(String)
    /// A request carrying a key to a non-https URL. Refused before anything was sent.
    case insecureTransport(String)
    /// A keyed backend with no key in the Keychain. Nothing was sent.
    case missingKey(NovaAIBackend)
    /// Non-2xx reply.
    case httpStatus(Int)
    /// A reply with no usable text.
    case emptyResponse
    /// A reply that couldn't be parsed.
    case badResponse
    /// The request timed out.
    case timedOut
    /// The app's validator rejected the reply.
    case validationFailed(String)
    /// The schema passed to `NovaAIJSONSchema` isn't a JSON object.
    case invalidSchema
    /// Every candidate failed; the last failure's description.
    case allBackendsFailed(String)

    public var errorDescription: String? {
        switch self {
        case .disabled: return "AI is turned off."
        case .noBackendAvailable: return "No AI backend is available."
        case .invalidURL(let u): return "Invalid AI backend URL: \(u)"
        case .insecureTransport(let host): return "Refused to send an API key over plain http to \(host). Use https."
        case .missingKey(let b): return "\(b.displayName) needs an API key (Settings > AI)."
        case .httpStatus(let c): return "The AI backend answered HTTP \(c)."
        case .emptyResponse: return "The AI backend returned an empty reply."
        case .badResponse: return "The AI backend returned an unreadable reply."
        case .timedOut: return "The AI backend timed out."
        case .validationFailed(let why): return "The AI reply was rejected: \(why)"
        case .invalidSchema: return "The JSON schema is not a JSON object."
        case .allBackendsFailed(let last): return "Every AI backend failed (last: \(last))."
        }
    }
}

/// Throw this (or any error) from a validator to reject a reply; `reason` is fed back to the model once.
public struct NovaAIValidationError: Error, Equatable, Sendable, LocalizedError {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

// MARK: - Never-throwing outcome

/// Where a value came from.
public enum NovaAISource: Sendable, Equatable {
    case ai(backend: NovaAIBackend, model: String)
    case fallback(NovaAIFallbackReason)

    public var isAI: Bool { if case .ai = self { return true } else { return false } }

    /// "AI · Ollama (qwen3:8b)" / "Built-in". Good for an AI-source label.
    public var label: String {
        switch self {
        case .ai(let b, let m): return "AI · \(b.displayName) (\(m))"
        case .fallback: return "Built-in"
        }
    }
}

/// Why the app's fallback was used.
public enum NovaAIFallbackReason: Sendable, Equatable {
    case disabled
    case unavailable(String)
    case validationFailed(String)
}

/// A value from AI or from the app's fallback, and which.
public struct NovaAIResult<Value: Sendable>: Sendable {
    public var value: Value
    public var source: NovaAISource
    /// The successful AI response, when the value came from AI.
    public var response: NovaAIResponse?

    public init(value: Value, source: NovaAISource, response: NovaAIResponse? = nil) {
        self.value = value
        self.source = source
        self.response = response
    }

    public var isAI: Bool { source.isAI }
}

/// One streamed event.
public enum NovaAIStreamEvent: Sendable, Equatable {
    /// More text (reasoning blocks already removed).
    case delta(String)
    /// The stream finished; `text` is the whole cleaned reply.
    case finished(NovaAIResponse)
}
