import Foundation
import Security

public enum LocalModelTokenError: Error, Equatable, LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let status): "Could not save the Hugging Face token to the Keychain (status \(status))."
        case .loadFailed(let status): "Could not read the Hugging Face token from the Keychain (status \(status))."
        case .deleteFailed(let status): "Could not remove the Hugging Face token from the Keychain (status \(status))."
        }
    }

    public var recoverySuggestion: String? {
        "Unlock the login keychain if prompted, then try again."
    }
}

/// Keeps the optional Hugging Face access token (needed only for gated models) in the Keychain.
/// It is never written to `UserDefaults`, a JSON store, or a log.
public enum LocalModelTokenStore {
    private static let service = "com.umbra.editor.localmodels"
    private static let account = "huggingface-token"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static func save(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try delete() }

        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw LocalModelTokenError.saveFailed(status) }
    }

    /// `nil` when no token has been saved.
    public static func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw LocalModelTokenError.loadFailed(status) }
        return String(data: data, encoding: .utf8)
    }

    public static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LocalModelTokenError.deleteFailed(status) }
    }
}
