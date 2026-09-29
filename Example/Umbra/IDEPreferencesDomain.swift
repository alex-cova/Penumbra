import Foundation

enum IDEPreferencesDomain: String, CaseIterable, Identifiable {
    case editor
    case appearance
    case focus
    case project
    case java

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: "Editor"
        case .appearance: "Appearance"
        case .focus: "Focus"
        case .project: "Project"
        case .java: "Java"
        }
    }

    var symbol: String {
        switch self {
        case .editor: "chevron.left.forwardslash.chevron.right"
        case .appearance: "paintbrush"
        case .focus: "scope"
        case .project: "folder"
        case .java: "cup.and.saucer"
        }
    }

    /// What the search field matches besides the title: the settings the pane holds.
    var searchTerms: [String] {
        switch self {
        case .editor:
            ["font", "font size", "line height", "typography", "tab width", "indent", "spaces", "keymap", "keyboard", "sublime", "intellij", "shortcuts"]
        case .appearance:
            ["theme", "color", "markdown headings", "line numbers", "folding", "word wrap", "minimap", "scrollbars", "right margin", "page guide", "method separators", "occurrences", "invisible characters", "metal", "renderer"]
        case .focus:
            ["typewriter", "distraction free", "focus mode", "writing"]
        case .project:
            ["explorer", "flatten packages"]
        case .java:
            ["jdk", "gradle", "sync", "timeout", "diagnostics", "compiler", "semantic highlighting", "parameter hints", "inlay", "gutter icons", "imports", "optimize imports"]
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(query)
            || searchTerms.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    var showsTypePreview: Bool {
        switch self {
        case .editor, .appearance: true
        case .focus, .project, .java: false
        }
    }
}
