import Foundation
import JavaIntelligence

/// Java and Gradle diagram requests. The ids match the tabs Umbra already opens, so two calls for
/// the same file, package, project or Gradle module still share one tab. The session never reads
/// these scopes: the workspace loader does, from the id.
extension IDEDiagramRequest {
    static func classes(_ scope: JavaClassGraphScope) -> IDEDiagramRequest {
        IDEDiagramRequest(
            id: classID(scope), title: classTitle(scope), symbolName: "square.stack.3d.up", presentation: .classes
        )
    }

    static var gradleModules: IDEDiagramRequest {
        IDEDiagramRequest(id: "gradle:modules", title: "Gradle Modules", symbolName: "shippingbox", presentation: .dependencies)
    }

    static func gradleLibraries(projectPath: String, configuration: String) -> IDEDiagramRequest {
        IDEDiagramRequest(
            id: "gradle:libraries:" + projectPath,
            title: "Dependencies: " + projectPath,
            symbolName: "cube.transparent",
            presentation: .dependencies,
            offersConfigurationPicker: true
        )
    }

    /// The scope encoded in a class-diagram id, for the loader. Nil for any other request.
    var classScope: JavaClassGraphScope? {
        if id == "classes:project" { return .project }
        if let name = id.removingPrefix("classes:package:") { return .package(name) }
        if let path = id.removingPrefix("classes:file:") { return .file(URL(fileURLWithPath: path)) }
        if let names = id.removingPrefix("classes:types:") {
            return .types(names.split(separator: ",").map(String.init).filter { !$0.isEmpty })
        }
        return nil
    }

    /// The Gradle project path of a library diagram (`:` for the root). Nil otherwise.
    var gradleProjectPath: String? {
        id.removingPrefix("gradle:libraries:")
    }

    private static func classID(_ scope: JavaClassGraphScope) -> String {
        switch scope {
        case .file(let url): "classes:file:" + url.standardizedFileURL.path
        case .package(let name): "classes:package:" + name
        case .types(let names): "classes:types:" + names.sorted().joined(separator: ",")
        case .project: "classes:project"
        }
    }

    private static func classTitle(_ scope: JavaClassGraphScope) -> String {
        switch scope {
        case .file(let url): "Classes: " + url.lastPathComponent
        case .package(let name): "Classes: " + (name.isEmpty ? "(default package)" : name)
        case .types(let names):
            "Classes: " + (names.first.map { String($0.split(separator: ".").last ?? Substring($0)) } ?? "")
                + (names.count > 1 ? " +\(names.count - 1)" : "")
        case .project: "Classes: Project"
        }
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
