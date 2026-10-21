import Foundation
import Security
import Synchronization

public enum SecretStoreError: Error, LocalizedError, Sendable {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

/// Storage for secrets (passwords, private keys). Accounts are `<dbId>.<field>` / `cert.<certId>.key`.
public protocol SecretStore: Sendable {
    func secret(for account: String) throws -> String?
    /// `nil` deletes the item.
    func setSecret(_ value: String?, for account: String) throws
}

public enum SecretAccount {
    public static func password(_ id: DatabaseID) -> String { "\(id.rawValue).password" }
    public static func sentinelPassword(_ id: DatabaseID) -> String { "\(id.rawValue).sentinelMaster.password" }
    public static func sshPassword(_ id: DatabaseID) -> String { "\(id.rawValue).ssh.password" }
    public static func sshPrivateKey(_ id: DatabaseID) -> String { "\(id.rawValue).ssh.privateKey" }
    public static func sshPassphrase(_ id: DatabaseID) -> String { "\(id.rawValue).ssh.passphrase" }
    public static func clientCertificateKey(_ certificateID: String) -> String { "cert.\(certificateID).key" }

    public static func all(for id: DatabaseID) -> [String] {
        [password(id), sentinelPassword(id), sshPassword(id), sshPrivateKey(id), sshPassphrase(id)]
    }
}

/// Generic-password Keychain items under one service (default `Keystrand`).
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = "Keystrand") {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func secret(for account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
        guard let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(_ value: String?, for account: String) throws {
        let query = baseQuery(account)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecretStoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw SecretStoreError.keychain(status)
        }
    }
}

/// Process-local secret store for tests and previews.
public final class InMemorySecretStore: SecretStore, Sendable {
    private let values = Mutex<[String: String]>([:])

    public init() {}

    public func secret(for account: String) throws -> String? {
        values.withLock { $0[account] }
    }

    public func setSecret(_ value: String?, for account: String) throws {
        values.withLock { $0[account] = value }
    }
}
