import AgentKit
import Foundation

/// Where the agent's permission rules live, and how they are read and written.
///
/// Sources, merged in this order (every deny, ask and allow from every source counts):
/// 1. the app's own file, for rules that follow the user everywhere;
/// 2. `.umbra/settings.json` in the project, which a team may commit;
/// 3. `.umbra/settings.local.json`, the user's own (what "Always allow" writes);
/// 4. `.claude/settings.json` and `.claude/settings.local.json`, read only, so a project that already
///    has Claude Code rules keeps them.
///
/// All of them are the same shape: `{"permissions": {"allow": [...], "ask": [...], "deny": [...]}}`.
enum IDEAgentPermissionFiles {
    enum Scope: Sendable {
        /// `.umbra/settings.local.json` in the project.
        case project
        /// The app's own file.
        case app
    }

    struct WriteError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    static let projectLocalPath = ".umbra/settings.local.json"

    /// `~/Library/Application Support/com.umbra.editor/permissions.json`.
    static func appFile() -> URL? {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("permissions.json")
    }

    /// Which file a set of rules came from, for a settings page that lists them.
    enum Origin: Sendable, Equatable {
        case app, projectShared, projectLocal, claudeShared, claudeLocal

        var title: String {
            switch self {
            case .app: "This Mac"
            case .projectShared: ".umbra/settings.json"
            case .projectLocal: ".umbra/settings.local.json"
            case .claudeShared: ".claude/settings.json (read only)"
            case .claudeLocal: ".claude/settings.local.json (read only)"
            }
        }

        /// Rules from `.claude` are Claude Code's; Umbra reads them and never writes them.
        var isEditable: Bool { self != .claudeShared && self != .claudeLocal }
    }

    /// Each source with the rules in it, in the order of `sources`, whether or not the file exists.
    static func loadEach(projectRoot: URL?, appFile: URL?) -> [(origin: Origin, url: URL, rules: PermissionRules)] {
        var list: [(Origin, URL)] = []
        if let appFile { list.append((.app, appFile)) }
        if let projectRoot {
            list += [
                (.projectShared, projectRoot.appendingPathComponent(".umbra/settings.json")),
                (.projectLocal, projectRoot.appendingPathComponent(projectLocalPath)),
                (.claudeShared, projectRoot.appendingPathComponent(".claude/settings.json")),
                (.claudeLocal, projectRoot.appendingPathComponent(".claude/settings.local.json")),
            ]
        }
        return list.map { origin, url in
            (origin, url, (try? Data(contentsOf: url)).map(PermissionRules.fromSettings) ?? PermissionRules())
        }
    }

    /// The files to read, lowest precedence first (it does not matter for the union, but it is the
    /// order a settings page lists them in).
    static func sources(projectRoot: URL?, appFile: URL?) -> [URL] {
        var urls: [URL] = []
        if let appFile { urls.append(appFile) }
        if let projectRoot {
            for path in [".umbra/settings.json", projectLocalPath, ".claude/settings.json", ".claude/settings.local.json"] {
                urls.append(projectRoot.appendingPathComponent(path))
            }
        }
        return urls
    }

    static func load(projectRoot: URL?, appFile: URL?) -> PermissionRules {
        sources(projectRoot: projectRoot, appFile: appFile).reduce(PermissionRules()) { rules, url in
            guard let data = try? Data(contentsOf: url) else { return rules }
            return rules.merged(with: PermissionRules.fromSettings(data))
        }
    }

    static func file(for scope: Scope, projectRoot: URL?, appFile: URL?) -> URL? {
        switch scope {
        case .project: projectRoot?.appendingPathComponent(projectLocalPath)
        case .app: appFile
        }
    }

    /// Adds `rule` to the file's `kind` list, creating the file (and `.umbra`) if need be and keeping
    /// everything else in it. A file that is not valid JSON is never overwritten: it may be hand-written.
    /// Returns whether the file changed.
    @discardableResult
    static func add(_ rule: PermissionRule, to kind: PermissionRules.Kind, in file: URL) throws -> Bool {
        var root = try readObject(file)
        var permissions = root["permissions"] as? [String: Any] ?? [:]
        let key = Self.key(kind)
        var list = permissions[key] as? [Any] ?? []
        guard !list.contains(where: { ($0 as? String).flatMap(PermissionRule.init(parsing:)) == rule }) else { return false }
        list.append(rule.description)
        permissions[key] = list
        root["permissions"] = permissions
        try write(root, to: file)
        return true
    }

    /// Removes every entry equal to `rule` from the file's `kind` list. Returns whether it changed.
    @discardableResult
    static func remove(_ rule: PermissionRule, from kind: PermissionRules.Kind, in file: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        var root = try readObject(file)
        guard var permissions = root["permissions"] as? [String: Any], let list = permissions[key(kind)] as? [Any] else { return false }
        let kept = list.filter { ($0 as? String).flatMap(PermissionRule.init(parsing:)) != rule }
        guard kept.count != list.count else { return false }
        permissions[key(kind)] = kept
        root["permissions"] = permissions
        try write(root, to: file)
        return true
    }

    private static func key(_ kind: PermissionRules.Kind) -> String {
        switch kind {
        case .allow: "allow"
        case .ask: "ask"
        case .deny: "deny"
        }
    }

    private static func readObject(_ file: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WriteError(message: "\(file.lastPathComponent) is not a JSON object, so it was left as it is. Fix or remove it, then try again.")
        }
        return object
    }

    private static func write(_ object: [String: Any], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
    }
}
