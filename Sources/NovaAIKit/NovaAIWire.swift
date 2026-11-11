//
//  NovaAIWire.swift
//  NovaAIKit
//
//  Wire formats (pure, network-free): Ollama /api/chat, OpenAI chat completions (MLX server, TinyLLM, TinyChat,
//  OpenWebUI, Nova fleet / Rosetta, OpenRouter, OpenAI) and the Nova Gateway's own /api/chat. Plus the
//  transport-security rule and the URLSession wrapper (timeouts → NovaAIError.timedOut).
//
//  Copyright © 2026 Jordan Koch.
//

import Foundation

enum NovaAIWire {
    // MARK: Transport security

    /// A base URL that is http(s) with a host, without trailing slashes; nil otherwise.
    static func baseURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard s.count <= NovaAISettings.maxURLLength, let u = URL(string: s),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty, u.user == nil, u.password == nil else { return nil }
        return u
    }

    static func isLoopback(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "localhost" || h == "::1" || h == "[::1]" || h.hasPrefix("127.")
    }

    /// May a key travel to `url` for `backend`? https always; plain http only to this machine (loopback) and only
    /// for backends whose key is optional (OpenWebUI). OpenRouter/OpenAI keys go over https only, full stop.
    static func keyAllowed(_ url: URL, backend: NovaAIBackend) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        return !backend.requiresKey && isLoopback(url.host)
    }

    /// Auth headers for a key.
    static func authHeaders(_ backend: NovaAIBackend, key: String, configuration: NovaAIConfiguration) -> [String: String] {
        var h = ["Authorization": "Bearer \(key)"]
        if backend == .openRouter {
            h["HTTP-Referer"] = configuration.appURL
            h["X-Title"] = configuration.appName
        }
        return h
    }

    // MARK: Bodies

    /// Messages capped per message; when the backend can't take the format natively, the JSON instruction goes into
    /// the system prompt.
    static func messages(_ request: NovaAIRequest, backend: NovaAIBackend, maxInput: Int) -> [[String: String]] {
        var msgs = request.messages.map { m in ["role": m.role.rawValue, "content": String(m.content.prefix(maxInput))] }
        let instruction: String?
        switch request.format {
        case .text: instruction = nil
        case .json: instruction = "Reply with a single JSON object only. No prose, no code fences."
        case .jsonSchema(let s):
            instruction = backend.supportsJSONSchema
                ? "Reply with a single JSON object only, matching the required schema. No prose, no code fences."
                : "Reply with a single JSON object only, matching this JSON Schema exactly. No prose, no code fences.\nSchema: \(s.text)"
        }
        if let instruction {
            if let i = msgs.firstIndex(where: { $0["role"] == "system" }) {
                msgs[i]["content"] = (msgs[i]["content"] ?? "") + "\n\n" + instruction
            } else {
                msgs.insert(["role": "system", "content": instruction], at: 0)
            }
        }
        return msgs
    }

    /// Ollama `/api/chat`. `think` follows `request.reasoning` (default false, so a reasoning model can't spend the
    /// whole budget thinking and return nothing); any `<think>` block that still appears is stripped.
    static func ollamaBody(_ request: NovaAIRequest, model: String, stream: Bool, maxInput: Int) -> [String: Any] {
        var body: [String: Any] = [
            "model": model, "stream": stream, "think": request.reasoning,
            "messages": messages(request, backend: .ollama, maxInput: maxInput),
            "options": ["temperature": request.temperature, "num_predict": request.maxTokens],
        ]
        switch request.format {
        case .text: break
        case .json: body["format"] = "json"
        case .jsonSchema(let s): body["format"] = s.object
        }
        return body
    }

    /// OpenAI chat completions.
    static func openAIBody(_ request: NovaAIRequest, backend: NovaAIBackend, model: String, stream: Bool, maxInput: Int) -> [String: Any] {
        var body: [String: Any] = [
            "model": model, "stream": stream,
            "messages": messages(request, backend: backend, maxInput: maxInput),
            "temperature": request.temperature, "max_tokens": request.maxTokens,
        ]
        if backend.supportsJSONSchema {
            switch request.format {
            case .text: break
            case .json: body["response_format"] = ["type": "json_object"]
            case .jsonSchema(let s):
                body["response_format"] = ["type": "json_schema",
                                           "json_schema": ["name": s.name, "schema": s.object, "strict": true] as [String: Any]]
            }
        }
        return body
    }

    /// The Nova Gateway's own `/api/chat` (`{"message","session_id","agent_id","person"}` → `{"ok","response"}`).
    /// The conversation is flattened into one message; `person` is "service" so nothing is remembered as Jordan.
    static func gatewayNativeBody(_ request: NovaAIRequest, appID: String, maxInput: Int) -> [String: Any] {
        let msgs = messages(request, backend: .novaGateway, maxInput: maxInput)
        var parts: [String] = []
        for m in msgs {
            switch m["role"] {
            case "system": parts.append("Instructions: \(m["content"] ?? "")")
            case "assistant": parts.append("Assistant: \(m["content"] ?? "")")
            default: parts.append(msgs.filter { $0["role"] != "system" }.count > 1 ? "User: \(m["content"] ?? "")" : (m["content"] ?? ""))
            }
        }
        return ["message": parts.joined(separator: "\n\n"), "session_id": "novaaikit-\(appID)", "agent_id": "chat", "person": "service"]
    }

    static func post(_ url: URL, body: [String: Any], headers: [String: String], timeout: TimeInterval) throws -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        guard JSONSerialization.isValidJSONObject(body) else { throw NovaAIError.badResponse }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    // MARK: Replies

    /// The assistant text of any supported reply shape (raw, before cleaning); nil when there is none.
    static func replyText(_ data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let ok = obj["ok"] as? Bool, ok == false { return nil }
            if let msg = obj["message"] as? [String: Any], let t = msg["content"] as? String { return t }
            if let choices = obj["choices"] as? [[String: Any]], let first = choices.first {
                if let msg = first["message"] as? [String: Any] {
                    if let t = msg["content"] as? String { return t }
                    if let parts = msg["content"] as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined() }
                }
                if let t = first["text"] as? String { return t }
            }
            for key in ["response", "content", "text", "output"] { if let t = obj[key] as? String { return t } }
            return nil
        }
        // Not one JSON document: a stream body (NDJSON or SSE) returned in one piece, or plain text.
        guard let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        let lines = s.components(separatedBy: .newlines)
        var acc = ""
        var sawStream = false
        for line in lines {
            switch streamLine(line) {
            case .text(let t): acc += t; sawStream = true
            case .done: sawStream = true
            case .ignore: continue
            }
        }
        return sawStream ? acc : s
    }

    enum StreamLine: Equatable { case text(String), done, ignore }

    /// One line of an Ollama NDJSON stream or an OpenAI SSE stream.
    static func streamLine(_ raw: String) -> StreamLine {
        var line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix(":") else { return .ignore }
        if line.hasPrefix("event:") || line.hasPrefix("id:") || line.hasPrefix("retry:") { return .ignore }
        if line.hasPrefix("data:") { line = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        if line == "[DONE]" { return .done }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .ignore }
        if let msg = obj["message"] as? [String: Any], let t = msg["content"] as? String {
            return (obj["done"] as? Bool) == true && t.isEmpty ? .done : .text(t)
        }
        if let choices = obj["choices"] as? [[String: Any]], let first = choices.first {
            if let d = first["delta"] as? [String: Any], let t = d["content"] as? String { return .text(t) }
            if let m = first["message"] as? [String: Any], let t = m["content"] as? String { return .text(t) }
            if let t = first["text"] as? String { return .text(t) }
            return .ignore
        }
        if (obj["done"] as? Bool) == true { return .done }
        for key in ["response", "content", "text"] { if let t = obj[key] as? String { return .text(t) } }
        return .ignore
    }

    /// Model names from a model-list reply: Ollama `{"models":[{"name"}]}` or OpenAI-style `{"data":[{"id"}]}`.
    static func modelNames(_ data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let models = obj["models"] as? [[String: Any]] {
            return models.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
        }
        if let models = obj["data"] as? [[String: Any]] { return models.compactMap { $0["id"] as? String } }
        return []
    }
}

// MARK: - HTTP

enum NovaAIHTTP {
    /// One request; non-2xx becomes `NovaAIError.httpStatus`, a timeout `NovaAIError.timedOut`.
    static func data(_ session: URLSession, _ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await mapErrors { try await raw(session, request) }
        guard let http = response as? HTTPURLResponse else { throw NovaAIError.badResponse }
        guard (200...299).contains(http.statusCode) else { throw NovaAIError.httpStatus(http.statusCode) }
        return (data, http)
    }

    /// Like `data` but returns the status instead of throwing on non-2xx (probes).
    static func status(_ session: URLSession, _ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await mapErrors { try await raw(session, request) }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Reads a reply line by line as it streams. `onLine` returns true to stop.
    static func lines(_ session: URLSession, _ request: URLRequest, onLine: (String) throws -> Bool) async throws {
        try await mapErrors {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NovaAIError.httpStatus(http.statusCode)
            }
            for try await line in bytes.lines {
                if try onLine(line) { break }
            }
        }
    }

    private static func mapErrors<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let e as URLError where e.code == .timedOut {
            throw NovaAIError.timedOut
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        }
    }

    private static func raw(_ session: URLSession, _ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
