import Foundation
import JavaIntelligence

enum IDEPreferencesDomain: String, CaseIterable, Identifiable {
    case editor
    case appearance
    case focus
    case project
    case java
    case inspections

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: "Editor"
        case .appearance: "Appearance"
        case .focus: "Focus"
        case .project: "Project"
        case .java: "Java"
        case .inspections: "Inspections"
        }
    }

    var symbol: String {
        switch self {
        case .editor: "chevron.left.forwardslash.chevron.right"
        case .appearance: "paintbrush"
        case .focus: "scope"
        case .project: "folder"
        case .java: "cup.and.saucer"
        case .inspections: "checklist"
        }
    }

    /// What the search field matches besides the title: the settings the pane holds.
    var searchTerms: [String] {
        switch self {
        case .editor:
            ["theme", "color", "font", "font size", "line height", "typography", "markdown headings", "tab width", "indent", "spaces", "line numbers", "folding", "word wrap", "minimap", "scrollbars", "right margin", "page guide", "method separators", "occurrences", "invisible characters", "metal", "renderer", "keymap", "keyboard", "sublime", "intellij", "shortcuts"]
        case .appearance:
            ["ui theme", "color scheme", "appearance", "visual studio", "resharper", "umbra light", "interface", "ui font", "ui font size", "interface font", "sf compact", "welcome", "background", "starfield", "deep space", "stars", "animation"]
        case .focus:
            ["typewriter", "distraction free", "focus mode", "writing"]
        case .project:
            ["explorer", "flatten packages"]
        case .inspections:
            ["warnings", "severity", "code analysis", "quick fix", "lint", "probable bugs", "redundant code", "unused", "suppress", "noinspection"] + JavaInspectionRule.allCases.map(\.title)
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
        case .editor: true
        case .appearance, .focus, .project, .java, .inspections: false
        }
    }
}
