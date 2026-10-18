import Foundation
import Security

/// Where a data source's password lives. One item per connection id; never a file.
protocol IDEDatabaseKeyStore: Sendable {
    func load(account: String) throws -> String?
    func save(_ secret: String, account: String) throws
    func delete(account: String) throws
}

enum IDEDatabaseKeychainError: Error, Equatable, LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status): "Could not save the password to the Keychain (status \(status))."
        case .loadFailed(let status): "Could not read the password from the Keychain (status \(status))."
        case .deleteFailed(let status): "Could not remove the password from the Keychain (status \(status))."
        }
    }
}

/// Generic-password items under one service. Readable only while the Mac is unlocked.
struct IDEDatabaseKeychain: IDEDatabaseKeyStore {
    static let service = "com.umbra.editor.database"

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    func save(_ secret: String, account: String) throws {
        guard !secret.isEmpty else { return try delete(account: account) }
        SecItemDelete(query(account: account) as CFDictionary)
        var add = query(account: account)
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw IDEDatabaseKeychainError.saveFailed(status) }
    }

    /// `nil` when no password has been saved.
    func load(account: String) throws -> String? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw IDEDatabaseKeychainError.loadFailed(status)
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IDEDatabaseKeychainError.deleteFailed(status)
        }
    }
}

/// For tests: the same contract without touching the login Keychain.
final class IDEDatabaseMemoryKeyStore: IDEDatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func load(account: String) throws -> String? { lock.withLock { secrets[account] } }

    func save(_ secret: String, account: String) throws {
        lock.withLock { secrets[account] = secret.isEmpty ? nil : secret }
    }

    func delete(account: String) throws { lock.withLock { secrets[account] = nil } }
}
