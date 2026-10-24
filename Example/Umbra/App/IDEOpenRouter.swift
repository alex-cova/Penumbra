import Foundation

/// What to do when a window already has a project and another folder is opened from inside it
/// (⌘O, Open Recent, dropping a folder on the window). The Open Folder prompt's "Remember my
/// choice" writes this setting.
enum IDEOpenFoldersIn: String, CaseIterable, Identifiable {
    case ask
    case newWindow
    case replace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask each time"
        case .newWindow: "Open in a new window"
        case .replace: "Replace this window's project"
        }
    }
}

/// A window as the router sees it: no AppKit, so the routing rules can be tested directly.
struct IDEOpenWindow: Equatable {
    let id: UUID
    var projectRoot: URL?
    /// No project and no documents: the Welcome screen.
    var isEmpty: Bool
    /// The window external opens are aimed at: the key window, else the one used last.
    var isPrimary: Bool
}

/// Where an open request came from. Only a request made inside a window can ask about replacing
/// that window's project; Dock drops and `open -a` have no window to ask about.
enum IDEOpenOrigin: Equatable {
    case external
    case window(UUID)
}

enum IDEOpenDecision: Equatable {
    /// The folder is already open there: bring that window (or tab) forward.
    case focus(UUID)
    /// That window is empty: open the folder in it.
    case reuse(UUID)
    /// The window has a project and the setting says replace it.
    case replace(UUID)
    /// The window has a project and the setting says ask: the window shows the prompt.
    case askReplaceOrNew(UUID)
    case newWindow
}

enum IDEOpenFileDecision: Equatable {
    case window(UUID)
    case newWindow
}

/// The routing rules for opening folders and files across windows (see
/// `docs/PER_WINDOW_PROJECTS_PLAN.md`):
///
/// - A folder that is already open goes to the window that has it.
/// - An empty window takes the folder.
/// - A window with a project asks, follows the `Open folders in` setting, or (for external opens)
///   gets a new window.
/// - A file goes to the window whose project contains it, else the primary window, else a new one.
struct IDEOpenRouter {
    /// Every open window.
    var windows: [IDEOpenWindow]
    var preference: IDEOpenFoldersIn

    func routeFolder(_ url: URL, origin: IDEOpenOrigin) -> IDEOpenDecision {
        let path = Self.normalizedPath(url)
        if let open = windows.first(where: { $0.projectRoot.map(Self.normalizedPath) == path }) {
            return .focus(open.id)
        }
        switch origin {
        case .external:
            if let primary = windows.first(where: \.isPrimary), primary.isEmpty {
                return .reuse(primary.id)
            }
            return .newWindow
        case .window(let id):
            guard let window = windows.first(where: { $0.id == id }) else { return .newWindow }
            if window.isEmpty {
                return .reuse(id)
            }
            switch preference {
            case .ask: return .askReplaceOrNew(id)
            case .newWindow: return .newWindow
            case .replace: return .replace(id)
            }
        }
    }

    func routeFile(_ url: URL) -> IDEOpenFileDecision {
        let path = Self.normalizedPath(url)
        // The deepest root wins, for a project nested inside another open one.
        let owner = windows
            .compactMap { window -> (IDEOpenWindow, Int)? in
                guard let root = window.projectRoot.map(Self.normalizedPath),
                      path == root || path.hasPrefix(root + "/") else { return nil }
                return (window, root.count)
            }
            .max { $0.1 < $1.1 }?
            .0
        if let owner {
            return .window(owner.id)
        }
        if let primary = windows.first(where: \.isPrimary) ?? windows.first {
            return .window(primary.id)
        }
        return .newWindow
    }

    /// Symlinks resolved and trailing slashes dropped, so `/tmp/p`, `/private/tmp/p/` and a link to
    /// it compare equal.
    static func normalizedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
