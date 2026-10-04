/// A tab of the left sidebar. The sidebar shows one at a time, in a single card, instead of a card
/// per tool window.
enum IDESidebarTab: String, Codable, CaseIterable, Identifiable {
    case explorer
    case structure
    case changes
    case breakpoints
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explorer: "Explorer"
        case .structure: "Structure"
        case .changes: "Changes"
        case .breakpoints: "Breakpoints"
        case .history: "History"
        }
    }

    var systemImage: String {
        switch self {
        case .explorer: "folder"
        case .structure: "list.bullet.indent"
        case .changes: "arrow.triangle.branch"
        case .breakpoints: "circle.fill"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// The Explorer is the sidebar's home: it stays when the others are closed.
    var isClosable: Bool { self != .explorer }
}
