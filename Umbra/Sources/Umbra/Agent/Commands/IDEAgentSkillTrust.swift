import AgentKit
import CryptoKit
import Foundation

/// Whether the user has let a repository's skill or command pre-approve tools (`allowed-tools`) for the run
/// they start with `/name`. Like the hooks and the MCP servers a project lists: the first time a given skill is
/// seen it is shown and asked about, the fingerprint of what was shown is stored, and a changed skill asks
/// again. Nothing here stops a skill from loading or from being read by the model: only the pre-approval of
/// tools waits for a yes. Skills in the user's own folders and Umbra's never ask.
final class IDEAgentSkillTrust: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var _trusted: Set<String>
    private var _declined: Set<String>

    private enum Keys {
        static let trusted = "umbra.agent.skillToolsTrusted"
        static let declined = "umbra.agent.skillToolsDeclined"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _trusted = Set(defaults.stringArray(forKey: Keys.trusted) ?? [])
        _declined = Set(defaults.stringArray(forKey: Keys.declined) ?? [])
    }

    /// What the user's answer is about: the kind, name, folder, tools and a hash of the text, so an edit to any
    /// of them asks again.
    static func fingerprint(kind: String, name: String, source: String, tools: [String], body: String) -> String {
        let bodyHash = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        let canonical = [kind, name.lowercased(), source, tools.sorted().joined(separator: "\u{1}"), bodyHash].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(of skill: Skill) -> String {
        fingerprint(kind: "skill", name: skill.name, source: skill.source, tools: skill.allowedTools, body: skill.body)
    }

    static func fingerprint(of command: CommandTemplate) -> String {
        fingerprint(kind: "command", name: command.name, source: command.source, tools: command.allowedTools, body: command.body)
    }

    func isTrusted(_ fingerprint: String) -> Bool { lock.withLock { _trusted.contains(fingerprint) } }
    func isDeclined(_ fingerprint: String) -> Bool { lock.withLock { _declined.contains(fingerprint) } }

    func trust(_ fingerprint: String) {
        lock.withLock {
            _trusted.insert(fingerprint)
            _declined.remove(fingerprint)
            save()
        }
    }

    func decline(_ fingerprint: String) {
        lock.withLock {
            _declined.insert(fingerprint)
            _trusted.remove(fingerprint)
            save()
        }
    }

    /// Takes back an answer, so the next run asks again.
    func forget(_ fingerprint: String) {
        lock.withLock {
            _trusted.remove(fingerprint)
            _declined.remove(fingerprint)
            save()
        }
    }

    private func save() {
        defaults.set(_trusted.sorted(), forKey: Keys.trusted)
        defaults.set(_declined.sorted(), forKey: Keys.declined)
    }
}

/// What `/name` may pre-approve for a skill or command.
enum IDEAgentSkillConsent {
    enum State: Equatable {
        /// Nothing to ask: no tools, or the user's own folder.
        case notNeeded
        case trusted
        case declined
        /// A repository's skill with tools, not answered yet.
        case unknown
    }

    static func state(scope: SkillScope, tools: [String], fingerprint: String, trust: IDEAgentSkillTrust) -> State {
        guard scope.comesFromRepository, !tools.isEmpty else { return .notNeeded }
        if trust.isTrusted(fingerprint) { return .trusted }
        if trust.isDeclined(fingerprint) { return .declined }
        return .unknown
    }

    static func state(of skill: Skill, trust: IDEAgentSkillTrust) -> State {
        state(scope: skill.scope, tools: skill.allowedTools, fingerprint: IDEAgentSkillTrust.fingerprint(of: skill), trust: trust)
    }

    static func state(of command: CommandTemplate, trust: IDEAgentSkillTrust) -> State {
        state(scope: command.scope, tools: command.allowedTools, fingerprint: IDEAgentSkillTrust.fingerprint(of: command), trust: trust)
    }

    /// Settles `.unknown` with a question and remembers the answer; the other states answer themselves.
    /// Returns the tools the run may pre-approve.
    @MainActor
    static func allowedTools(
        state: State, fingerprint: String, tools: [String], trust: IDEAgentSkillTrust, confirm: () async -> Bool
    ) async -> (tools: [String], declined: Bool) {
        switch state {
        case .notNeeded, .trusted:
            return (tools, false)
        case .declined:
            return ([], true)
        case .unknown:
            if await confirm() {
                trust.trust(fingerprint)
                return (tools, false)
            }
            trust.decline(fingerprint)
            return ([], true)
        }
    }
}
