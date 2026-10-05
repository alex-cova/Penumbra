import DiagramKit
import Foundation
import JavaIntelligence

/// What a diagram tab shows. Two requests with the same ``id`` are the same tab.
nonisolated enum IDEDiagramRequest: Hashable, Sendable {
    /// The UML classes of a file, package, some types, or the whole project.
    case classes(JavaClassGraphScope)
    /// The Gradle projects of the build and which depend on which.
    case gradleModules
    /// The libraries one Gradle project resolves for a configuration.
    case gradleLibraries(projectPath: String, configuration: String)
    /// The JSON buffer open in an editor, drawn over that editor. Not a diagram tab: every preview
    /// shares one id because the session lives on the pane, not in `diagramSessions`.
    case jsonPreview(title: String)

    var id: String {
        switch self {
        case .classes(.file(let url)): "classes:file:" + url.standardizedFileURL.path
        case .classes(.package(let name)): "classes:package:" + name
        case .classes(.types(let names)): "classes:types:" + names.sorted().joined(separator: ",")
        case .classes(.project): "classes:project"
        case .gradleModules: "gradle:modules"
        case .gradleLibraries(let projectPath, _): "gradle:libraries:" + projectPath
        case .jsonPreview: "json:preview"
        }
    }

    var title: String {
        switch self {
        case .classes(.file(let url)): "Classes: " + url.lastPathComponent
        case .classes(.package(let name)): "Classes: " + (name.isEmpty ? "(default package)" : name)
        case .classes(.types(let names)):
            "Classes: " + (names.first.map { String($0.split(separator: ".").last ?? Substring($0)) } ?? "")
                + (names.count > 1 ? " +\(names.count - 1)" : "")
        case .classes(.project): "Classes: Project"
        case .gradleModules: "Gradle Modules"
        case .gradleLibraries(let projectPath, _): "Dependencies: " + projectPath
        case .jsonPreview(let title): title
        }
    }

    var symbolName: String {
        switch self {
        case .classes: "square.stack.3d.up"
        case .gradleModules: "shippingbox"
        case .gradleLibraries: "cube.transparent"
        case .jsonPreview: "curlybraces"
        }
    }

    var isClassDiagram: Bool {
        if case .classes = self { return true }
        return false
    }

    var isGradleDiagram: Bool {
        switch self {
        case .gradleModules, .gradleLibraries: true
        case .classes, .jsonPreview: false
        }
    }

    var isJSONPreview: Bool {
        if case .jsonPreview = self { return true }
        return false
    }
}
