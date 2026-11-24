import Foundation
import Security

struct GitHubCredential: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let identity: GitHubIdentity
    let tokens: GitHubTokenPair

    var description: String { "GitHub credential" }
    var debugDescription: String { description }
}

protocol GitHubCredentialStore: Sendable {
    func identities() throws -> [GitHubIdentity]
    func load(userID: Int64) throws -> GitHubCredential?
    func save(_ credential: GitHubCredential) throws
    func remove(userID: Int64) throws
}

enum GitHubCredentialError: Error, Equatable {
    case invalidRecord
    case keychain(OSStatus)
}

/// The account actor serializes these synchronous Security.framework operations off the main actor.
struct GitHubKeychain: GitHubCredentialStore {
    private let service: String
    private let usesDataProtection: Bool

    init(distributionIdentifier: String, clientID: String) {
        service = "\(distributionIdentifier).github.v1.\(clientID)"
        if let task = SecTaskCreateFromSelf(nil) {
            let identifier = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil)
            let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil)
            usesDataProtection = (identifier as? String)?.isEmpty == false || (groups as? [String])?.isEmpty == false
        } else {
            usesDataProtection = false
        }
    }

    func identities() throws -> [GitHubIdentity] {
        var request = query()
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try Self.requireSuccess(status)
        guard let items = result as? [[String: Any]] else { throw GitHubCredentialError.invalidRecord }
        return try items.map { attributes in
            guard let account = attributes[kSecAttrAccount as String] as? String,
                  let id = Int64(account), id > 0,
                  let login = attributes[kSecAttrLabel as String] as? String, !login.isEmpty
            else { throw GitHubCredentialError.invalidRecord }
            return GitHubIdentity(id: id, login: login)
        }
    }

    func load(userID: Int64) throws -> GitHubCredential? {
        var request = query(userID: userID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try Self.requireSuccess(status)
        guard let data = result as? Data,
              let credential = try? JSONDecoder().decode(GitHubCredential.self, from: data),
              credential.identity.id == userID
        else { throw GitHubCredentialError.invalidRecord }
        return credential
    }

    func save(_ credential: GitHubCredential) throws {
        let match = query(userID: credential.identity.id)
        let values: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(credential),
            kSecAttrLabel as String: credential.identity.login
        ]
        let update = SecItemUpdate(match as CFDictionary, values as CFDictionary)
        guard update == errSecItemNotFound else { return try Self.requireSuccess(update) }

        var item = match.merging(values) { _, value in value }
        if usesDataProtection {
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let add = SecItemAdd(item as CFDictionary, nil)
        if add == errSecDuplicateItem {
            try Self.requireSuccess(SecItemUpdate(match as CFDictionary, values as CFDictionary))
        } else {
            try Self.requireSuccess(add)
        }
    }

    func remove(userID: Int64) throws {
        let status = SecItemDelete(query(userID: userID) as CFDictionary)
        if status != errSecItemNotFound { try Self.requireSuccess(status) }
    }

    private func query(userID: Int64? = nil) -> [String: Any] {
        var match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        // Unprovisioned Developer ID builds use the file-based Keychain's app access controls.
        // Select the backend from the signature so an operation failure never changes it.
        if usesDataProtection {
            match[kSecUseDataProtectionKeychain as String] = true
            match[kSecAttrSynchronizable as String] = false
        }
        if let userID { match[kSecAttrAccount as String] = String(userID) }
        return match
    }

    private static func requireSuccess(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw GitHubCredentialError.keychain(status) }
    }
}
