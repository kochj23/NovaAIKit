//
//  NovaAIKeychain.swift
//  NovaAIKit
//
//  API keys live only in the Keychain (service `com.jkoch.<appID>.<backend>`, account `apiKey`). Never
//  UserDefaults, environment variables or files. Based on the games' KeychainStore (update in place to keep the
//  item's ACL; empty value deletes).
//
//  Copyright © 2026 Jordan Koch.
//

import Foundation
import Security

/// Secret storage. The real one is `NovaAIKeychain`; tests use `NovaAIMemoryKeyStore`.
public protocol NovaAIKeyStore: Sendable {
    func read(service: String, account: String) -> String?
    /// Store or replace; an empty value deletes. Returns true on success.
    @discardableResult func write(_ value: String, service: String, account: String) -> Bool
    /// Returns true when the item was removed or didn't exist.
    @discardableResult func delete(service: String, account: String) -> Bool
}

/// The system Keychain (generic passwords).
public struct NovaAIKeychain: NovaAIKeyStore {
    /// Data Protection keychain group; nil uses the login keychain (macOS) / app keychain (iOS, tvOS).
    public var accessGroup: String?
    /// Prefix of the item label shown in Keychain Access.
    public var labelPrefix: String

    public init(accessGroup: String? = nil, labelPrefix: String = "NovaAIKit") {
        self.accessGroup = accessGroup
        self.labelPrefix = labelPrefix
    }

    private func query(_ service: String, _ account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            q[kSecUseDataProtectionKeychain as String] = true
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        return q
    }

    public func read(service: String, account: String) -> String? {
        var q = query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    public func write(_ value: String, service: String, account: String) -> Bool {
        guard !value.isEmpty else { return delete(service: service, account: account) }
        guard let data = value.data(using: .utf8) else { return false }
        let base = query(service, account)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "\(labelPrefix) API key (\(service))"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func delete(service: String, account: String) -> Bool {
        let status = SecItemDelete(query(service, account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// In-memory key store for tests and previews. Never touches the Keychain.
public final class NovaAIMemoryKeyStore: NovaAIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    /// When true, every write fails (to test that migration deletes nothing).
    public var failWrites = false

    public init(_ items: [String: String] = [:]) { self.items = items }

    private func k(_ s: String, _ a: String) -> String { s + "\u{1}" + a }

    public func read(service: String, account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[k(service, account)]
    }

    @discardableResult
    public func write(_ value: String, service: String, account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if failWrites { return false }
        items[k(service, account)] = value.isEmpty ? nil : value
        return true
    }

    @discardableResult
    public func delete(service: String, account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        items[k(service, account)] = nil
        return true
    }

    /// Number of stored items (tests).
    public var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
}

/// Outcome of a one-time key migration.
public enum NovaAIKeyMigrationResult: Equatable, Sendable {
    /// Copied into the new service (and the legacy copy removed if asked).
    case migrated
    /// The new service already has a key; nothing was changed.
    case alreadyPresent
    /// No legacy key found.
    case nothingToMigrate
    /// Writing (or reading back) the new item failed; the legacy item was left untouched.
    case writeFailed
}

/// API-key operations for one app. Used by `NovaAI`; usable on its own (e.g. a CLI).
public struct NovaAIKeys: Sendable {
    public let configuration: NovaAIConfiguration
    public let store: any NovaAIKeyStore

    public init(configuration: NovaAIConfiguration, store: (any NovaAIKeyStore)? = nil) {
        self.configuration = configuration
        self.store = store ?? NovaAIKeychain(accessGroup: configuration.keychainAccessGroup,
                                             labelPrefix: configuration.appName)
    }

    /// The key for `backend`, trimmed; nil when none is stored or the backend takes no key.
    public func key(for backend: NovaAIBackend) -> String? {
        guard backend.acceptsKey else { return nil }
        let k = store.read(service: configuration.keychainService(for: backend), account: NovaAIConfiguration.keychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (k?.isEmpty ?? true) ? nil : k
    }

    public func hasKey(for backend: NovaAIBackend) -> Bool { key(for: backend) != nil }

    /// Store (non-empty) or delete (nil/empty) the key for `backend`.
    @discardableResult
    public func setKey(_ value: String?, for backend: NovaAIBackend) -> Bool {
        guard backend.acceptsKey else { return false }
        let v = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let service = configuration.keychainService(for: backend)
        return v.isEmpty ? store.delete(service: service, account: NovaAIConfiguration.keychainAccount)
                         : store.write(v, service: service, account: NovaAIConfiguration.keychainAccount)
    }

    /// One-time copy of a key from an old Keychain item into this app's service for `backend`.
    /// Reads the legacy item, writes the new one, reads it back, and only then (if `deleteLegacy`) deletes the
    /// legacy item. Leave `deleteLegacy` false when another app may still use the old item
    /// (e.g. `com.jkoch.aistudio.openrouter`).
    /// - Parameter legacyStore: where the old item lives (a different access group); default: this store.
    public func migrateLegacyKey(service: String, account: String, to backend: NovaAIBackend,
                                 deleteLegacy: Bool = false, legacyStore: (any NovaAIKeyStore)? = nil) -> NovaAIKeyMigrationResult {
        guard backend.acceptsKey else { return .nothingToMigrate }
        let old = legacyStore ?? store
        let newService = configuration.keychainService(for: backend)
        if service == newService && account == NovaAIConfiguration.keychainAccount && legacyStore == nil { return .alreadyPresent }
        if hasKey(for: backend) { return .alreadyPresent }
        guard let value = old.read(service: service, account: account)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return .nothingToMigrate }
        guard setKey(value, for: backend), key(for: backend) == value else { return .writeFailed }
        if deleteLegacy { old.delete(service: service, account: account) }
        return .migrated
    }

    /// One-time move of a key an old version kept in UserDefaults (plaintext) into the Keychain. The defaults
    /// entry is removed only after the Keychain write is verified. If the Keychain already has a key, the
    /// plaintext copy is removed too (it must not stay in UserDefaults).
    public func migrateLegacyDefaultsKey(_ key: String, defaults: UserDefaults = .standard,
                                         to backend: NovaAIBackend) -> NovaAIKeyMigrationResult {
        guard backend.acceptsKey else { return .nothingToMigrate }
        guard let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
            return .nothingToMigrate
        }
        if hasKey(for: backend) {
            defaults.removeObject(forKey: key)
            return .alreadyPresent
        }
        guard setKey(value, for: backend), self.key(for: backend) == value else { return .writeFailed }
        defaults.removeObject(forKey: key)
        return .migrated
    }

    /// Keychain accounts the old `AIBackendManager` used for the removed Google/Azure/AWS/IBM backends.
    public static let obsoleteLegacyAccounts = ["googleCloudAPIKey", "azureAPIKey", "azureEndpoint", "awsAccessKey",
                                                "awsSecretKey", "ibmWatsonAPIKey", "ibmWatsonURL"]

    /// Deletes the removed backends' secrets from an old Keychain service (they have no successor).
    /// Returns the accounts that were deleted. Only deletes; never reads values out.
    @discardableResult
    public func deleteObsoleteLegacyItems(service: String, accounts: [String] = NovaAIKeys.obsoleteLegacyAccounts,
                                          legacyStore: (any NovaAIKeyStore)? = nil) -> [String] {
        let old = legacyStore ?? store
        return accounts.filter { a in
            guard old.read(service: service, account: a) != nil else { return false }
            return old.delete(service: service, account: a)
        }
    }
}
