import Foundation

/// What a window shows. `editor` is Umbra as an editor; `ai` is AI mode, a layout over the whole
/// window with Chat and Code, while the editor stays mounted underneath so its carets and scroll
/// positions survive the switch.
enum IDEWindowMode: String, Codable, Sendable {
    case editor
    case ai
}

/// The two halves of AI mode. Chat is a plain conversation with any model and no project (the
/// Ollama app); Code is the agent working in a project folder (Claude Code).
enum IDEAITab: String, Codable, CaseIterable, Identifiable, Sendable {
    case chat
    case code

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .code: "Code"
        }
    }

    var symbolName: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Asks the window that ends up with a project to show it in AI mode, and to resume a saved chat
/// of that project. Carried by the window registry, since the window that gets the folder is only
/// known once the router has chosen it (and may not exist yet).
struct IDEAIOpenRequest: Equatable, Sendable {
    var resumeChat: UUID?
}
