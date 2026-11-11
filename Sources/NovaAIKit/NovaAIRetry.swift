//
//  NovaAIRetry.swift
//  NovaAIKit
//
//  Bounded retry with exponential backoff (from GTNW Retry.swift) and the per-endpoint health memory Auto uses
//  to skip a server that just failed (from CarTest's BackendHealth).
//
//  Copyright © 2026 Jordan Koch.
//

import Foundation

/// How many times to try one backend, and how long to wait between tries.
public struct NovaAIRetryPolicy: Equatable, Sendable {
    /// Total attempts including the first (clamped to 1…5).
    public var maxAttempts: Int
    /// Delay before the 2nd attempt.
    public var baseDelay: TimeInterval
    /// Growth factor between attempts.
    public var multiplier: Double
    /// Upper bound on one delay.
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 2, baseDelay: TimeInterval = 0.5, multiplier: Double = 2, maxDelay: TimeInterval = 4) {
        self.maxAttempts = min(max(1, maxAttempts), 5)
        self.baseDelay = max(0, baseDelay)
        self.multiplier = max(1, multiplier)
        self.maxDelay = max(0, maxDelay)
    }

    /// Default for chat calls: 2 attempts per backend, 0.5 s backoff, then fail over.
    public static let network = NovaAIRetryPolicy()
    /// One attempt only.
    public static let none = NovaAIRetryPolicy(maxAttempts: 1)

    /// Delay after failed attempt `attempt` (1-based).
    public func delay(afterAttempt attempt: Int) -> TimeInterval {
        min(baseDelay * pow(multiplier, Double(max(1, attempt) - 1)), maxDelay)
    }

    /// Total sleep if every attempt fails.
    public var worstCaseSleep: TimeInterval {
        maxAttempts > 1 ? (1..<maxAttempts).reduce(0) { $0 + delay(afterAttempt: $1) } : 0
    }
}

/// Injectable sleep, so tests run in microseconds.
public typealias NovaAISleeper = @Sendable (TimeInterval) async -> Void

public enum NovaAIRetry {
    /// Real sleep; returns early when the task is cancelled.
    public static let taskSleep: NovaAISleeper = { seconds in
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Run `body`, retrying retryable failures with backoff. Rethrows the last error.
    /// - Parameter attempts: incremented once per call of `body` (for reporting).
    public static func run<T: Sendable>(_ policy: NovaAIRetryPolicy, sleep: NovaAISleeper = taskSleep,
                                        shouldRetry: @Sendable (Error) -> Bool = isRetryable,
                                        onAttempt: @Sendable () -> Void = {},
                                        _ body: @Sendable () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            onAttempt()
            do { return try await body() } catch {
                guard attempt < policy.maxAttempts, shouldRetry(error), !(error is CancellationError), !Task.isCancelled else {
                    throw error
                }
                await sleep(policy.delay(afterAttempt: attempt))
                attempt += 1
            }
        }
    }

    /// Fast transient failures worth another try on the same server: 408, 429, 5xx, a dropped connection.
    /// Timeouts and refused connections are not retried — Auto fails over instead (they already cost time).
    public static func isRetryable(_ error: Error) -> Bool {
        if case NovaAIError.httpStatus(let code) = error { return code == 408 || code == 429 || (500...599).contains(code) }
        if let u = error as? URLError { return u.code == .networkConnectionLost }
        return false
    }

    /// Failures that mean the server is down or unusable right now (Auto skips it for `healthTTL`).
    public static func isUnreachable(_ error: Error) -> Bool {
        if case NovaAIError.httpStatus(let code) = error { return code >= 500 || code == 401 || code == 403 || code == 429 }
        if case NovaAIError.timedOut = error { return true }
        return error is URLError
    }
}

/// Reachability per base URL, shared by every call of one `NovaAI`: a server that just failed is skipped by Auto
/// for `ttl` seconds, then tried again. Thread-safe.
public final class NovaAIHealth: @unchecked Sendable {
    public let ttl: TimeInterval
    private let lock = NSLock()
    private var seen: [String: (ok: Bool, at: Date)] = [:]
    private var native: Set<String> = []
    private let now: @Sendable () -> Date

    public init(ttl: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.now = now
    }

    public func mark(_ endpoint: String, ok: Bool) {
        lock.lock(); seen[endpoint] = (ok, now()); lock.unlock()
    }

    /// true/false when seen within `ttl`; nil when unknown or stale.
    public func status(_ endpoint: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard let s = seen[endpoint], now().timeIntervalSince(s.at) < ttl else { return nil }
        return s.ok
    }

    public func reset() {
        lock.lock(); seen.removeAll(); native.removeAll(); lock.unlock()
    }

    /// Nova Gateway URLs that answered 404 to the OpenAI path and speak the gateway's own `/api/chat`.
    func usesGatewayNative(_ endpoint: String) -> Bool { lock.lock(); defer { lock.unlock() }; return native.contains(endpoint) }
    func setGatewayNative(_ endpoint: String) { lock.lock(); native.insert(endpoint); lock.unlock() }
}

/// Counts attempts across concurrent closures.
final class NovaAICounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
