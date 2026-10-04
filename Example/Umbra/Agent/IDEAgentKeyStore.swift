import Foundation
import Security

/// Where agent API keys live. One key per endpoint host; never `UserDefaults`, never a session file.
protocol IDEAgentKeyStore: Sendable {
    func load(account: String) throws -> String?
    func save(_ key: String, account: String) throws
    func delete(account: String) throws
}

enum IDEAgentKeychainError: Error, Equatable, LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status): "Could not save the API key to the Keychain (status \(status))."
        case .loadFailed(let status): "Could not read the API key from the Keychain (status \(status))."
        case .deleteFailed(let status): "Could not remove the API key from the Keychain (status \(status))."
        }
    }
}

/// Generic-password items under one service. Readable only while the Mac is unlocked.
struct IDEAgentKeychain: IDEAgentKeyStore {
    static let service = "com.umbra.editor.agent"

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    func save(_ key: String, account: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try delete(account: account) }
        SecItemDelete(query(account: account) as CFDictionary)
        var add = query(account: account)
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw IDEAgentKeychainError.saveFailed(status) }
    }

    /// `nil` when no key has been saved.
    func load(account: String) throws -> String? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw IDEAgentKeychainError.loadFailed(status) }
        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw IDEAgentKeychainError.deleteFailed(status) }
    }
}

/// For tests: the same contract without touching the user's Keychain.
final class IDEAgentMemoryKeyStore: IDEAgentKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]

    func load(account: String) throws -> String? { lock.withLock { keys[account] } }

    func save(_ key: String, account: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock { keys[account] = trimmed.isEmpty ? nil : trimmed }
    }

    func delete(account: String) throws { lock.withLock { keys[account] = nil } }
}
