//
//  NovaAIBackend.swift
//  NovaAIKit
//
//  The canonical backend ids shared by every app (from the games' LLMBackendType). Raw values are stable,
//  lowercase and persisted; display names are separate. The cloud providers (OpenAI, Anthropic, Gemini, xAI,
//  Mistral, DeepSeek, Meta, OpenRouter) each need their own Keychain key and https. Google Cloud (Vertex)/Azure/AWS/
//  IBM Watson are deliberately absent: they were stubs that never worked.
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
    case anthropic = "anthropic"
    case gemini = "gemini"
    case xAI = "xai"
    case mistral = "mistral"
    case deepSeek = "deepseek"
    case meta = "meta"

    public var id: String { rawValue }

    /// Auto's fixed failover order: local first, then Nova's fleet (skipped when `settings.allowNova` is off), then
    /// the keyed cloud backends (each only when its key is stored). MLX is left out on iOS/tvOS (it needs a Mac).
    public static var autoOrder: [NovaAIBackend] {
        [.ollama, .mlx, .tinyChat, .tinyLLM, .openWebUI, .novaGateway,
         .openRouter, .openAI, .anthropic, .gemini, .xAI, .mistral, .deepSeek, .meta].filter(\.isSupportedOnThisPlatform)
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
        case .openAI: return "OpenAI (ChatGPT)"
        case .anthropic: return "Anthropic Claude"
        case .gemini: return "Google Gemini"
        case .xAI: return "xAI Grok"
        case .mistral: return "Mistral"
        case .deepSeek: return "DeepSeek"
        case .meta: return "Meta (Model API)"
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
        case .anthropic: return "text.bubble"
        case .gemini: return "sparkle"
        case .xAI: return "xmark.circle"
        case .mistral: return "wind"
        case .deepSeek: return "water.waves"
        case .meta: return "infinity"
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
        case .openAI: return "OpenAI API (ChatGPT models). https only."
        case .anthropic: return "Anthropic Messages API (Claude). https only."
        case .gemini: return "Google Gemini API (OpenAI-compatible endpoint). https only."
        case .xAI: return "xAI API (Grok). https only."
        case .mistral: return "Mistral AI API. https only."
        case .deepSeek: return "DeepSeek API. https only."
        case .meta: return "Meta Model API (Muse models; Meta's current developer API). https only."
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
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .xAI: return "https://api.x.ai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .deepSeek: return "https://api.deepseek.com"
        case .meta: return "https://api.meta.ai/v1"
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
        case .openAI: return "gpt-6-luna"
        case .anthropic: return "claude-sonnet-5-5"
        case .gemini: return "gemini-3.8-flash"
        case .xAI: return "grok-4.7"
        case .mistral: return "mistral-small-latest"
        case .deepSeek: return "deepseek-flash"
        case .meta: return "muse-spark-1.3"
        }
    }

    /// Model names offered when the backend can't list its own (picker fallback).
    public var fallbackModels: [String] {
        switch self {
        case .openRouter:
            return ["anthropic/claude-sonnet-4.5", "openai/gpt-4o", "google/gemini-2.0-flash-001",
                    "meta-llama/llama-3.3-70b-instruct", "deepseek/deepseek-chat"]
        case .openAI: return ["gpt-6-luna", "gpt-6-astra"]
        case .anthropic: return ["claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5-5"]
        case .gemini: return ["gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-3.1-pro-preview"]
        case .xAI: return ["grok-4.7", "grok-build-0.1"]
        case .mistral: return ["mistral-small-latest", "mistral-large-latest"]
        case .deepSeek: return ["deepseek-flash", "deepseek-v4-pro"]
        case .meta: return ["muse-spark-1.3", "muse-ember-1.0", "muse-wonder-1.0"]
        case .novaGateway: return ["nova", "conversation", "code", "fast", "reasoner"]
        case .auto: return []
        default: return [defaultModel]
        }
    }

    /// Cloud backends: never called without a Keychain key, and only over https.
    public var requiresKey: Bool {
        [.openRouter, .openAI, .anthropic, .gemini, .xAI, .mistral, .deepSeek, .meta].contains(self)
    }

    /// Backends that send a key when one is stored (required or optional).
    public var acceptsKey: Bool { requiresKey || self == .openWebUI }

    /// Wire protocol: Ollama's `/api/chat`, Anthropic's `/messages`, or OpenAI chat completions for everything else.
    public var speaksOllama: Bool { self == .ollama }

    /// Anthropic's native Messages API. Its OpenAI-compatible endpoint forwards `temperature`, which current Claude
    /// models reject, so Claude gets its own wire format (`x-api-key`, `anthropic-version`, no sampling fields).
    public var speaksAnthropic: Bool { self == .anthropic }

    /// Accepts a JSON schema natively (Ollama `format`, OpenAI `response_format`, Anthropic `output_config.format`).
    /// Others get the schema in the system prompt; the kit always extracts and validates the JSON either way.
    public var supportsJSONSchema: Bool {
        [.ollama, .openRouter, .openAI, .novaGateway, .anthropic, .gemini, .xAI, .mistral].contains(self)
    }

    /// Path appended to the base URL for a chat request.
    public var chatPath: String {
        switch self {
        case .auto: return ""
        case .ollama: return "/api/chat"
        case .tinyChat: return "/api/chat/stream"
        case .openWebUI: return "/api/chat/completions"
        case .anthropic: return "/messages"
        case .openRouter, .openAI, .gemini, .xAI, .mistral, .deepSeek, .meta: return "/chat/completions"  // base has the version
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
        case .openRouter, .openAI, .anthropic, .gemini, .xAI, .mistral, .deepSeek, .meta: return "/models"
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
    /// "Auto (Prefer Ollama)", lowercase ids) to a canonical backend. The removed stubs (Google Cloud AI, Azure, AWS,
    /// IBM Watson) still map to Auto, not to Gemini: they had no working key to carry over (Google Cloud AI was a Vertex
    /// stub, Gemini needs a Gemini API key), and Auto keeps such an app working with no setup.
    public init?(legacyName raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let b = NovaAIBackend(rawValue: s) { self = b; return }
        switch s {
        case "mlx toolkit", "mlx native", "mlx (apple silicon)": self = .mlx
        case "open webui": self = .openWebUI
        case "nova gateway", "nova", "gateway": self = .novaGateway
        case "openrouter (frontier models)", "open router": self = .openRouter
        case "chatgpt", "openai (chatgpt)": self = .openAI
        case "claude", "anthropic claude", "anthropic (claude)": self = .anthropic
        case "google gemini", "gemini api": self = .gemini
        case "grok", "xai grok", "x.ai": self = .xAI
        case "mistral ai": self = .mistral
        case "llama", "llama api", "meta llama", "meta (model api)", "meta model api": self = .meta
        case _ where s.hasPrefix("auto"): self = .auto
        case "google cloud ai", "googlecloud", "microsoft azure", "azurecognitive", "aws ai services", "awsai",
             "ibm watson", "ibmwatson":
            self = .auto
        default: return nil
        }
    }
}
