import CryptoKit
import Foundation

/// Whether the user has approved a project's `hooks` block. Like the MCP server trust: the
/// first time a project's block is seen it is shown and asked about, the fingerprint of the
/// block is stored, and a changed block asks again. A hook from an untrusted project never
/// runs. App-level hooks are the user's own and need no prompt.
final class IDEAgentHookTrust: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var _trusted: Set<String>
    private var _declined: Set<String>

    private enum Keys {
        static let trusted = "umbra.agent.hooksTrusted"
        static let declined = "umbra.agent.hooksDeclined"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _trusted = Set(defaults.stringArray(forKey: Keys.trusted) ?? [])
        _declined = Set(defaults.stringArray(forKey: Keys.declined) ?? [])
    }

    var trusted: Set<String> { lock.withLock { _trusted } }
    var declined: Set<String> { lock.withLock { _declined } }

    /// What the user's yes is about: a hash of everything a hook would run.
    static func fingerprint(of entries: [IDEAgentHookEntry]) -> String {
        let canonical = entries.map {
            "\($0.event.rawValue)|\($0.matcher)|\($0.command)|\($0.timeout)|\($0.required)"
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func isTrusted(_ fingerprint: String) -> Bool { lock.withLock { _trusted.contains(fingerprint) } }
    func isDeclined(_ fingerprint: String) -> Bool { lock.withLock { _declined.contains(fingerprint) } }

    func trust(_ fingerprint: String) {
        lock.withLock {
            _trusted.insert(fingerprint)
            _declined.remove(fingerprint)
            defaults.set(_trusted.sorted(), forKey: Keys.trusted)
            defaults.set(_declined.sorted(), forKey: Keys.declined)
        }
    }

    func decline(_ fingerprint: String) {
        lock.withLock {
            _declined.insert(fingerprint)
            _trusted.remove(fingerprint)
            defaults.set(_trusted.sorted(), forKey: Keys.trusted)
            defaults.set(_declined.sorted(), forKey: Keys.declined)
        }
    }
}

/// Decides which loaded hooks a session may use. App-level hooks are the user's own; project
/// hooks run only after the user approves exactly this block (`confirm` shows it), and a
/// changed block asks again. Anything unapproved never runs.
@MainActor
enum IDEAgentHookConsent {
    static func resolve(
        entries: [IDEAgentHookEntry], trust: IDEAgentHookTrust,
        confirm: () async -> Bool
    ) async -> [IDEAgentHookEntry] {
        let appHooks = entries.filter { $0.origin == .app }
        let projectHooks = entries.filter { $0.origin != .app }
        guard !projectHooks.isEmpty else { return appHooks }
        let fingerprint = IDEAgentHookTrust.fingerprint(of: projectHooks)
        if trust.isTrusted(fingerprint) { return entries }
        if trust.isDeclined(fingerprint) { return appHooks }
        if await confirm() {
            trust.trust(fingerprint)
            return entries
        }
        trust.decline(fingerprint)
        return appHooks
    }
}
