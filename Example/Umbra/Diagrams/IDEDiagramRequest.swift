import Foundation

/// What kind of picture a diagram tab is. The session uses this for its toolbar and its summary.
/// It does not say which language produced the picture.
enum IDEDiagramPresentation: Hashable, Sendable {
    /// Types and their members.
    case classes
    /// Modules or libraries and the links between them.
    case dependencies
    /// A JSON value drawn over its editor. Not a diagram tab.
    case jsonPreview
}

/// What a diagram tab shows. Two requests with the same ``id`` are the same tab. The graph itself
/// is loaded by the opener (`IDEDiagramSession.load`) and comes back as an ``IDEDiagramLoad``.
nonisolated struct IDEDiagramRequest: Hashable, Sendable {
    var id: String
    var title: String
    var symbolName: String
    var presentation: IDEDiagramPresentation
    /// The toolbar offers the dependency configuration picker.
    var offersConfigurationPicker: Bool

    init(
        id: String, title: String, symbolName: String, presentation: IDEDiagramPresentation,
        offersConfigurationPicker: Bool = false
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.presentation = presentation
        self.offersConfigurationPicker = offersConfigurationPicker
    }

    var isClassDiagram: Bool { presentation == .classes }
    var isDependencyDiagram: Bool { presentation == .dependencies }
    /// Kept for the JSON preview, which is neither a class diagram nor a dependency diagram.
    var isGradleDiagram: Bool { isDependencyDiagram }
    var isJSONPreview: Bool { presentation == .jsonPreview }

    static func jsonPreview(title: String) -> IDEDiagramRequest {
        IDEDiagramRequest(id: "json:preview", title: title, symbolName: "curlybraces", presentation: .jsonPreview)
    }
}

/// One load of a diagram: the document before layout, and what to say when it is empty or failed.
struct IDEDiagramLoad: Sendable {
    var document: IDEDiagramDocument
    var notice: String?
    var emptyMessage: String
    var failure: String?

    init(document: IDEDiagramDocument, notice: String? = nil, emptyMessage: String = "", failure: String? = nil) {
        self.document = document
        self.notice = notice
        self.emptyMessage = emptyMessage
        self.failure = failure
    }
}
