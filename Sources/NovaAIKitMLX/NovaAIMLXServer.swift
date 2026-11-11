//
//  NovaAIMLXServer.swift
//  NovaAIKitMLX
//
//  Optional on-device MLX support, kept out of the core product.
//
//  Design choice (documented in README): the core `mlx` backend talks to `mlx_lm.server` over HTTP
//  (OpenAI-compatible, localhost:8081). Pulling mlx-swift into a shared package forces a Metal shader build that
//  plain `swift build`/`swift test` can't do, plus a macOS 14 floor that the macOS 12/13 apps can't take. Instead:
//    • `NovaAIMLXServer` starts/stops `mlx_lm.server` for apps that want MLX without the user running it by hand.
//    • `NovaAILocalModel` (core) lets an app that already links mlx-swift (MLX Code) plug its in-process engine in.
//
//  Copyright © 2026 Jordan Koch.
//

import Foundation
import NovaAIKit

#if os(macOS)
/// Launches `python3 -m mlx_lm.server --model <m> --host 127.0.0.1 --port <p>` and stops it again.
/// Only ever binds to loopback. Thread-safe.
public final class NovaAIMLXServer: @unchecked Sendable {
    public let python: String
    public let model: String
    public let port: Int
    private let lock = NSLock()
    private var process: Process?

    /// - Parameters:
    ///   - python: python interpreter with `mlx-lm` installed (absolute path; default `/usr/bin/env python3`).
    ///   - model: Hugging Face id of an MLX model, e.g. `mlx-community/Qwen3-8B-4bit`.
    ///   - port: default 8081 (the kit's MLX default URL).
    public init(python: String = "/usr/bin/env", model: String = NovaAIBackend.mlx.defaultModel, port: Int = 8081) {
        self.python = python
        self.model = model
        self.port = port
    }

    /// The base URL to put in settings for the `mlx` backend.
    public var baseURL: String { "http://127.0.0.1:\(port)" }

    /// The command line (for logs and tests). The model id is validated (no spaces/shell syntax).
    public var arguments: [String] {
        let pre = python.hasSuffix("/env") ? ["python3"] : []
        return pre + ["-m", "mlx_lm.server", "--model", model, "--host", "127.0.0.1", "--port", String(port)]
    }

    /// True when `model` is a plausible model id or local path (letters, digits, `/._-:`).
    public static func isValidModel(_ m: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-:")
        return !m.isEmpty && m.count <= 200 && m.allSatisfy { allowed.contains($0) } && !m.hasPrefix("-")
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning ?? false }

    /// Starts the server (no-op when already running). Output goes to `logFile` (or is discarded).
    public func start(logFile: URL? = nil) throws {
        guard Self.isValidModel(model) else { throw NovaAIError.invalidURL(model) }
        lock.lock(); defer { lock.unlock() }
        if process?.isRunning == true { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = arguments
        if let logFile {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
            let h = try FileHandle(forWritingTo: logFile)
            p.standardOutput = h
            p.standardError = h
        } else {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        try p.run()
        process = p
    }

    /// Stops the server if this object started it.
    public func stop() {
        lock.lock(); let p = process; process = nil; lock.unlock()
        if p?.isRunning == true { p?.terminate() }
    }

    /// Waits until the server answers `/v1/models` (or `timeout` passes). Returns true when it is up.
    public func waitUntilReady(timeout: TimeInterval = 120, session: URLSession = .shared) async -> Bool {
        guard let url = URL(string: baseURL + "/v1/models") else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var r = URLRequest(url: url)
            r.timeoutInterval = 2
            if let code = try? await status(session, r), code == 200 { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return false }
        }
        return false
    }

    private func status(_ session: URLSession, _ r: URLRequest) async throws -> Int {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
            session.dataTask(with: r) { _, resp, err in
                if let err { c.resume(throwing: err) } else { c.resume(returning: (resp as? HTTPURLResponse)?.statusCode ?? 0) }
            }.resume()
        }
    }

    deinit { stop() }
}
#endif

/// Wraps any async closure as a `NovaAILocalModel` — the adapter an app uses to plug an in-process MLX engine
/// (mlx-swift `ModelContainer`, etc.) into the `mlx` backend without NovaAIKit depending on mlx-swift.
public struct NovaAIClosureModel: NovaAILocalModel {
    public typealias Complete = @Sendable ([NovaAIMessage], Double, Int) async throws -> String
    private let available: @Sendable () async -> Bool
    private let body: Complete

    public init(isAvailable: @escaping @Sendable () async -> Bool = { true }, complete: @escaping Complete) {
        self.available = isAvailable
        self.body = complete
    }

    public func isAvailable() async -> Bool { await available() }

    public func complete(messages: [NovaAIMessage], temperature: Double, maxTokens: Int) async throws -> String {
        try await body(messages, temperature, maxTokens)
    }
}
