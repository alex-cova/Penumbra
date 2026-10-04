import AgentKit
import Foundation
import Observation

/// What Settings ▸ Agent ▸ Permissions shows and does: every rule with the file it came from, adding
/// and removing in the files Umbra owns, and asking "would this command run?".
@MainActor
@Observable
final class IDEAgentPermissionsModel {
    struct Entry: Identifiable, Equatable {
        let rule: PermissionRule
        let kind: PermissionRules.Kind
        let origin: IDEAgentPermissionFiles.Origin
        let file: URL

        var id: String { "\(origin.title)|\(kind)|\(rule)" }
    }

    /// A file's entries, for a list with one header per source.
    struct Group: Identifiable, Equatable {
        let origin: IDEAgentPermissionFiles.Origin
        let entries: [Entry]
        var id: String { origin.title }
    }

    private(set) var groups: [Group] = []
    private(set) var error: String?

    @ObservationIgnored private let projectRoot: () -> URL?
    @ObservationIgnored private let appFile: URL?

    init(projectRoot: @escaping () -> URL?, appFile: URL?) {
        self.projectRoot = projectRoot
        self.appFile = appFile
        reload()
    }

    var isEmpty: Bool { groups.allSatisfy { $0.entries.isEmpty } }

    func reload() {
        groups = IDEAgentPermissionFiles.loadEach(projectRoot: projectRoot(), appFile: appFile).map { source in
            func entries(_ rules: [PermissionRule], _ kind: PermissionRules.Kind) -> [Entry] {
                rules.map { Entry(rule: $0, kind: kind, origin: source.origin, file: source.url) }
            }
            return Group(
                origin: source.origin,
                entries: entries(source.rules.deny, .deny) + entries(source.rules.ask, .ask) + entries(source.rules.allow, .allow))
        }
    }

    /// Adds the rule written as text. A text that is not a rule is reported and nothing is written.
    func add(_ text: String, kind: PermissionRules.Kind, scope: IDEAgentPermissionFiles.Scope) {
        error = nil
        guard let rule = PermissionRule(parsing: text) else {
            error = "“\(text.trimmingCharacters(in: .whitespacesAndNewlines))” is not a rule. Write a tool, or a tool with a pattern: Bash(npm test:*), Edit(src/**)."
            return
        }
        guard let file = IDEAgentPermissionFiles.file(for: scope, projectRoot: projectRoot(), appFile: appFile) else {
            error = "Open a project folder to save a project rule."
            return
        }
        do {
            try IDEAgentPermissionFiles.add(rule, to: kind, in: file)
        } catch {
            self.error = error.localizedDescription
        }
        reload()
    }

    func remove(_ entry: Entry) {
        error = nil
        guard entry.origin.isEditable else { return }
        do {
            try IDEAgentPermissionFiles.remove(entry.rule, from: entry.kind, in: entry.file)
        } catch {
            self.error = error.localizedDescription
        }
        reload()
    }

    /// What would happen to `command` in `mode` with the rules as they are now.
    func verdict(forCommand command: String, mode: PermissionMode, secretPatterns: [GlobPattern] = []) async -> PermissionVerdict {
        let rules = groups.flatMap(\.entries).reduce(into: PermissionRules()) { $0.add($1.rule, to: $1.kind) }
        return await PermissionPolicy.evaluate(
            ToolCallInfo(name: "run_command", risk: .command, subject: .command(command)),
            mode: mode, rules: rules, secretPatterns: secretPatterns)
    }

    static func describe(_ verdict: PermissionVerdict) -> String {
        switch verdict {
        case .allow: "Runs without asking."
        case .ask(let notes): notes.first ?? "Asks first."
        case .deny(let reason): reason
        }
    }
}
