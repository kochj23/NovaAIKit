//
//  NovaAIBackend.swift
//  NovaAIKit
//
//  The canonical backend ids shared by every app (from the games' LLMBackendType). Raw values are stable,
//  lowercase and persisted; display names are separate. Google/Azure/AWS/IBM Watson are deliberately absent:
//  they were stubs that never worked. Claude is reached through `openRouter` or `novaGateway`.
//
//  Copyright © 2026 Jordan Koch.
//

import Foundation

/// An AI backend. `auto` walks `autoOrder` and uses the first one that answers.
public enum NovaAIBackend: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case auto = "auto"
    case ollama = "ollama"
    case mlx = "mlx"
    case tinyLLM = "tinyllm"
    case tinyChat = "tinychat"
    case openWebUI = "openwebui"
    case novaGateway = "novagateway"
    case openRouter = "openrouter"
    case openAI = "openai"

    public var id: String { rawValue }

    /// Auto's fixed failover order: local first, then Nova's fleet, then the keyed cloud backends.
    /// MLX is left out on iOS/tvOS (it needs a Mac).
    public static var autoOrder: [NovaAIBackend] {
        [.ollama, .mlx, .tinyChat, .tinyLLM, .openWebUI, .novaGateway, .openRouter, .openAI].filter(\.isSupportedOnThisPlatform)
    }

    /// Every backend the pickers offer on this platform (Auto first).
    public static var selectable: [NovaAIBackend] { [.auto] + autoOrder }

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .ollama: return "Ollama"
        case .mlx: return "MLX (Apple Silicon)"
        case .tinyLLM: return "TinyLLM"
        case .tinyChat: return "TinyChat"
        case .openWebUI: return "OpenWebUI"
        case .novaGateway: return "Nova Gateway / Fleet"
        case .openRouter: return "OpenRouter"
        case .openAI: return "OpenAI"
        }
    }

    /// SF Symbol for pickers and the status indicator.
    public var symbolName: String {
        switch self {
        case .auto: return "sparkles"
        case .ollama: return "network"
        case .mlx: return "cpu"
        case .tinyLLM: return "cube"
        case .tinyChat: return "bubble.left.and.bubble.right"
        case .openWebUI: return "globe"
        case .novaGateway: return "point.3.connected.trianglepath.dotted"
        case .openRouter: return "cloud"
        case .openAI: return "cloud.fill"
        }
    }

    /// One line for the settings screen.
    public var summary: String {
        switch self {
        case .auto: return "Tries every configured backend in a fixed order and uses the first that answers."
        case .ollama: return "Local or LAN Ollama server (/api/chat)."
        case .mlx: return "Apple Silicon: mlx_lm.server (OpenAI-compatible), or an in-process engine the app plugs in."
        case .tinyLLM: return "TinyLLM server (OpenAI-compatible)."
        case .tinyChat: return "TinyChat by Jason Cox."
        case .openWebUI: return "Self-hosted OpenWebUI (optional API key)."
        case .novaGateway: return "Nova Gateway or any OpenAI-compatible fleet endpoint (inference router, Rosetta)."
        case .openRouter: return "Frontier models (Claude, GPT, Gemini…) with one key. https only."
        case .openAI: return "OpenAI API. https only."
        }
    }

    /// Localhost defaults; every one is editable in settings.
    public var defaultURL: String {
        switch self {
        case .auto: return ""
        case .ollama: return "http://localhost:11434"
        case .mlx: return "http://localhost:8081"
        case .tinyLLM: return "http://localhost:8000"
        case .tinyChat: return "http://localhost:8000"
        case .openWebUI: return "http://localhost:8080"
        case .novaGateway: return "http://127.0.0.1:18792"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAI: return "https://api.openai.com/v1"
        }
    }

    /// The model used until the user picks one.
    public var defaultModel: String {
        switch self {
        case .auto: return ""
        case .ollama: return "qwen3:8b"
        case .mlx: return "mlx-community/Qwen3-8B-4bit"
        case .tinyLLM, .tinyChat: return "tinyllm"
        case .openWebUI: return "qwen3:8b"
        case .novaGateway: return "nova"
        case .openRouter: return "anthropic/claude-sonnet-4.5"
        case .openAI: return "gpt-4o-mini"
        }
    }

    /// Model names offered when the backend can't list its own (picker fallback).
    public var fallbackModels: [String] {
        switch self {
        case .openRouter:
            return ["anthropic/claude-sonnet-4.5", "openai/gpt-4o", "google/gemini-2.0-flash-001",
                    "meta-llama/llama-3.3-70b-instruct", "deepseek/deepseek-chat"]
        case .openAI: return ["gpt-4o-mini", "gpt-4o"]
        case .novaGateway: return ["nova", "conversation", "code", "fast", "reasoner"]
        case .auto: return []
        default: return [defaultModel]
        }
    }

    /// Cloud backends: never called without a Keychain key, and only over https.
    public var requiresKey: Bool { self == .openRouter || self == .openAI }

    /// Backends that send a key when one is stored (required or optional).
    public var acceptsKey: Bool { requiresKey || self == .openWebUI }

    /// Wire protocol: Ollama's `/api/chat`, or OpenAI chat completions for everything else.
    public var speaksOllama: Bool { self == .ollama }

    /// Accepts a JSON schema natively (Ollama `format`, OpenAI `response_format`). Others get the schema in the
    /// system prompt; the kit always extracts and validates the JSON either way.
    public var supportsJSONSchema: Bool { [.ollama, .openRouter, .openAI, .novaGateway].contains(self) }

    /// Path appended to the base URL for a chat request.
    public var chatPath: String {
        switch self {
        case .auto: return ""
        case .ollama: return "/api/chat"
        case .tinyChat: return "/api/chat/stream"
        case .openWebUI: return "/api/chat/completions"
        case .openRouter, .openAI: return "/chat/completions"     // base already ends in /v1
        case .mlx, .tinyLLM, .novaGateway: return "/v1/chat/completions"
        }
    }

    /// Path appended to the base URL for the model list (also the reachability probe).
    public var modelsPath: String {
        switch self {
        case .auto: return ""
        case .ollama: return "/api/tags"
        case .tinyChat: return "/"
        case .openWebUI: return "/api/models"
        case .openRouter, .openAI: return "/models"
        case .mlx, .tinyLLM, .novaGateway: return "/v1/models"
        }
    }

    /// MLX needs macOS on Apple Silicon.
    public var isSupportedOnThisPlatform: Bool {
        #if os(macOS)
        return true
        #else
        return self != .mlx
        #endif
    }

    /// Maps the names older apps persisted (display names of the old `AIBackendManager.AIBackend`, GTNW's
    /// "Auto (Prefer Ollama)", lowercase ids) to a canonical backend. Removed clouds (Google/Azure/AWS/IBM) map to Auto.
    public init?(legacyName raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let b = NovaAIBackend(rawValue: s) { self = b; return }
        switch s {
        case "mlx toolkit", "mlx native", "mlx (apple silicon)": self = .mlx
        case "open webui": self = .openWebUI
        case "nova gateway", "nova", "gateway": self = .novaGateway
        case "openrouter (frontier models)", "open router": self = .openRouter
        case _ where s.hasPrefix("auto"): self = .auto
        case "google cloud ai", "googlecloud", "microsoft azure", "azurecognitive", "aws ai services", "awsai",
             "ibm watson", "ibmwatson":
            self = .auto
        default: return nil
        }
    }
}
