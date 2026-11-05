import EditorIntelligence
import Foundation

/// One segment in the status bar breadcrumb. A folder lists its contents and a file its
/// siblings, to switch files; a package lists the classes and subpackages inside it; a symbol
/// lists the enclosing type's members (Java) or jumps in-file.
struct IDEBreadcrumbItem: Equatable, Identifiable {
    enum Target: Equatable {
        case folder(URL)
        case file(URL)
        /// A Java or Kotlin package directory. The title may be a dotted name covering several folders.
        case package(URL)
        case symbol(EditorIntelligence.TextRange)
    }

    let id: String
    let title: String
    let target: Target
}

/// Folder path, filename and enclosing symbols for the active document. Empty when nothing is open.
struct IDEHeaderContext: Equatable {
    var documentID: UUID?
    var pathItems: [IDEBreadcrumbItem] = []
    var symbolItems: [IDEBreadcrumbItem] = []
    var isDirty = false

    var items: [IDEBreadcrumbItem] { pathItems + symbolItems }
}

/// Holds the workspace for the Java navigation provider without capturing `IDEWorkspace` in a
/// `@Sendable` closure. The provider calls it off the main actor and hops back here.
final class NavigationBufferBridge: @unchecked Sendable {
    nonisolated(unsafe) weak var workspace: IDEWorkspace?
}
