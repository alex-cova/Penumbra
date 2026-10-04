import AgentKit
import Foundation

/// The commands and skills a window offers: the built-ins, then what is in the project's and the
/// user's `commands` and `skills` folders. Reading is cheap (a few small files) but the list is asked
/// for on every keystroke after a slash, so it is kept for a moment.
@MainActor
final class IDEAgentCommandCatalog {
    /// How long a read stays good.
    static let lifetime: TimeInterval = 2

    private let root: () -> URL?
    private let loadsUserFolders: () -> Bool
    private let home: URL?
    private let appSupport: URL?
    private var cached: (catalog: SkillCatalog, at: Date, key: String)?
    private let now: () -> Date

    /// `home` is the user folder holding `.claude`, and `appSupport` Umbra's own; `nil` for either means
    /// none (tests, which must not read the real ones).
    init(
        root: @escaping () -> URL?, loadsUserFolders: @escaping () -> Bool, home: URL?, appSupport: URL?,
        now: @escaping () -> Date = Date.init
    ) {
        self.root = root
        self.loadsUserFolders = loadsUserFolders
        self.home = home
        self.appSupport = appSupport
        self.now = now
    }

    /// Folders in the order they win: the project's before the user's.
    func folders(_ kind: String) -> [SkillCatalog.Location] {
        var folders: [SkillCatalog.Location] = []
        if let root = root() {
            folders.append(.init(url: root.appendingPathComponent(".umbra/\(kind)"), label: ".umbra/\(kind)"))
            folders.append(.init(url: root.appendingPathComponent(".claude/\(kind)"), label: ".claude/\(kind)"))
        }
        if loadsUserFolders(), let home {
            folders.append(.init(url: home.appendingPathComponent(".claude/\(kind)"), label: "~/.claude/\(kind)"))
        }
        if let appSupport {
            folders.append(.init(url: appSupport.appendingPathComponent(kind), label: "Umbra \(kind)"))
        }
        return folders
    }

    var skillCatalog: SkillCatalog {
        let key = (root()?.path ?? "") + "|\(loadsUserFolders())"
        if let cached, cached.key == key, now().timeIntervalSince(cached.at) < Self.lifetime { return cached.catalog }
        let catalog = SkillCatalog.load(skillFolders: folders("skills"), commandFolders: folders("commands"))
        cached = (catalog, now(), key)
        return catalog
    }

    /// Forget what was read, so the next ask reads again (the panel opening, a send).
    func invalidate() { cached = nil }

    /// Built-ins first; a command or skill that reuses a built-in's name is not listed, and a skill that
    /// reuses a command's name yields to the command.
    var descriptors: [IDEAgentCommandDescriptor] {
        let catalog = skillCatalog
        var list = IDEAgentBuiltInCommand.allCases.map { IDEAgentCommandDescriptor(name: $0.rawValue, kind: .builtIn($0)) }
        var taken = Set(list.map { $0.name.lowercased() })
        for command in catalog.commands where taken.insert(command.name.lowercased()).inserted {
            list.append(IDEAgentCommandDescriptor(name: command.name, kind: .custom(command)))
        }
        for skill in catalog.skills where taken.insert(skill.name.lowercased()).inserted {
            list.append(IDEAgentCommandDescriptor(name: skill.name, kind: .skill(skill)))
        }
        return list
    }

    func descriptor(named name: String) -> IDEAgentCommandDescriptor? {
        descriptors.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
