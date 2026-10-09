import Foundation

/// One page of Settings: what the sidebar row shows and what the search field matches. The built-in
/// pages are static members; a language module adds its own through ``IDEPreferencesPane`` and they
/// slot in between Project and Agent (``ordered(with:)``).
struct IDEPreferencesDomain: Hashable, Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// What the search field matches besides the title: the settings the page holds.
    let searchTerms: [String]
    /// Whether the editor type preview sits under the page.
    let showsTypePreview: Bool

    init(id: String, title: String, symbol: String, searchTerms: [String] = [], showsTypePreview: Bool = false) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.searchTerms = searchTerms
        self.showsTypePreview = showsTypePreview
    }

    static func == (lhs: IDEPreferencesDomain, rhs: IDEPreferencesDomain) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static let general = IDEPreferencesDomain(
        id: "general", title: "General", symbol: "gearshape",
        searchTerms: ["local history", "retention", "revisions", "days", "megabytes"]
    )
    static let editor = IDEPreferencesDomain(
        id: "editor", title: "Editor", symbol: "chevron.left.forwardslash.chevron.right",
        searchTerms: ["theme", "color", "font", "font size", "line height", "typography", "markdown headings", "tab width", "indent", "spaces", "line numbers", "folding", "word wrap", "minimap", "scrollbars", "right margin", "page guide", "method separators", "occurrences", "invisible characters", "metal", "renderer", "keymap", "keyboard", "sublime", "intellij", "shortcuts"],
        showsTypePreview: true
    )
    static let appearance = IDEPreferencesDomain(
        id: "appearance", title: "Appearance", symbol: "paintbrush",
        searchTerms: ["ui theme", "color scheme", "appearance", "visual studio", "resharper", "umbra light", "interface", "ui font", "ui font size", "interface font", "sf compact", "welcome", "background", "starfield", "deep space", "stars", "animation"]
    )
    static let focus = IDEPreferencesDomain(
        id: "focus", title: "Focus", symbol: "scope",
        searchTerms: ["typewriter", "distraction free", "focus mode", "writing"]
    )
    static let project = IDEPreferencesDomain(
        id: "project", title: "Project", symbol: "folder", searchTerms: ["explorer", "flatten packages"]
    )
    static let agent = IDEPreferencesDomain(
        id: "agent", title: "Agent", symbol: "sparkles",
        searchTerms: ["agent", "ai", "model", "openai", "ollama", "mlx", "api key", "provider", "plan", "approve edits", "autonomy", "context", "compaction", "history", "conversations", "secrets", "protected files", "environment", "steps", "iterations"]
    )

    /// The pages before the language modules' and the one after them.
    static let leading: [IDEPreferencesDomain] = [.general, .editor, .appearance, .focus, .project]

    /// Built-in pages with `modules`' in the middle, in the order they have always had.
    static func ordered(with modules: [IDEPreferencesDomain]) -> [IDEPreferencesDomain] {
        leading + modules + [.agent]
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(query)
            || searchTerms.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
