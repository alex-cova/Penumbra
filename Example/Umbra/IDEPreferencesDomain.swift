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

    var showsTypePreview: Bool {
        switch self {
        case .editor, .appearance: true
        case .focus, .project, .java: false
        }
    }
}
