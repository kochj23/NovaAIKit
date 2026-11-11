//
//  NovaAIText.swift
//  NovaAIKit
//
//  Pure text helpers: reasoning removal, JSON extraction, and the grounding/plain-text checks the games use to
//  validate output (from CarTest NovaAI.swift and StuntDriver LLMClient.swift). All network-free.
//
//  Copyright © 2026 Jordan Koch.
//

import Foundation

public enum NovaAIText {
    /// Removes `<think>…</think>` blocks (and a dangling `…</think>` prefix), trims. nil when nothing is left.
    public static func clean(_ raw: String, max: Int = .max) -> String? {
        var text = raw
        while let open = text.range(of: "<think>") {
            let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex)
            text.removeSubrange(open.lowerBound..<(close?.upperBound ?? text.endIndex))
        }
        if let r = text.range(of: "</think>") { text = String(text[r.upperBound...]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > max ? String(text.prefix(max)) : text
    }

    /// The outermost JSON object (or array) in a reply — code fences and chatter dropped. nil when there is none.
    public static func jsonPayload(_ text: String) -> String? {
        func span(_ open: Character, _ close: Character) -> ClosedRange<String.Index>? {
            guard let a = text.firstIndex(of: open), let b = text.lastIndex(of: close), a < b else { return nil }
            return a...b
        }
        let candidates = [span("{", "}"), span("[", "]")].compactMap { $0 }
        // Whichever starts first is the outer value.
        return candidates.min { $0.lowerBound < $1.lowerBound }.map { String(text[$0]) }
    }

    /// Decode `T` from the JSON in a reply (fences and chatter tolerated).
    public static func decode<T: Decodable>(_ type: T.Type, from text: String, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        guard let payload = jsonPayload(text), let data = payload.data(using: .utf8) else {
            throw NovaAIValidationError("The reply contained no JSON object.")
        }
        do { return try decoder.decode(T.self, from: data) } catch {
            throw NovaAIValidationError("The JSON did not match the required shape: \(Self.describe(error))")
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let k, _)?: return "missing key '\(k.stringValue)'"
        case .typeMismatch(_, let c)?: return "wrong type at '\(c.codingPath.map(\.stringValue).joined(separator: "."))'"
        case .valueNotFound(_, let c)?: return "null at '\(c.codingPath.map(\.stringValue).joined(separator: "."))'"
        case .dataCorrupted?: return "invalid JSON"
        default: return "\(error)"
        }
    }

    /// Numbers in a text ("12.50" → "12.5", "4,100" → "4100").
    public static func numbers(_ s: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: #"\d[\d,]*(?:\.\d+)?"#) else { return [] }
        let ns = s as NSString
        return Set(re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
            var n = ns.substring(with: $0.range).replacingOccurrences(of: ",", with: "")
            if n.contains(".") {
                while n.hasSuffix("0") { n.removeLast() }
                if n.hasSuffix(".") { n.removeLast() }
            }
            return n
        })
    }

    /// True when every number in `text` already appears in `source` (no invented figures).
    public static func grounded(_ text: String, in source: String) -> Bool { numbers(text).isSubset(of: numbers(source)) }

    /// Plain display text: no control characters (newlines kept), no markdown emphasis/headings, capped.
    public static func plain(_ s: String, max: Int = 1200) -> String {
        let scalars = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }
        var t = String(String.UnicodeScalarView(scalars)).replacingOccurrences(of: "[*#_`]", with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > max ? String(t.prefix(max)) : t
    }

    /// Numbered/bulleted list lines ("1. x", "- y", "• z") without their markers.
    public static func listItems(_ s: String) -> [String] {
        s.components(separatedBy: .newlines).compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            let stripped = t.replacingOccurrences(of: #"^(\d+[.)]|[-*•])\s*"#, with: "", options: .regularExpression)
            return stripped.isEmpty ? nil : stripped
        }
    }
}

/// Streaming `<think>` filter: feed chunks, get visible text; tags split across chunks are handled.
struct NovaAIThinkFilter {
    private var buffer = ""
    private var inThink = false

    mutating func feed(_ chunk: String) -> String {
        buffer += chunk
        var out = ""
        while true {
            if inThink {
                guard let r = buffer.range(of: "</think>") else {
                    // Keep a tail that could be the start of "</think>".
                    buffer = String(buffer.suffix(7))
                    return out
                }
                buffer = String(buffer[r.upperBound...])
                inThink = false
            } else {
                if let r = buffer.range(of: "<think>") {
                    out += buffer[..<r.lowerBound]
                    buffer = String(buffer[r.upperBound...])
                    inThink = true
                    continue
                }
                // Hold back a possible partial "<think>" at the end.
                var hold = 0
                for n in stride(from: min(6, buffer.count), through: 1, by: -1) where "<think>".hasPrefix(buffer.suffix(n)) {
                    hold = n
                    break
                }
                out += buffer.dropLast(hold)
                buffer = String(buffer.suffix(hold))
                return out
            }
        }
    }

    /// Whatever is held back at the end of the stream.
    mutating func finish() -> String {
        defer { buffer = "" }
        return inThink ? "" : buffer
    }
}
