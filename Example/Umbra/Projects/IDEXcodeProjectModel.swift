import Foundation
import XcodeProjectFormat

/// What Umbra knows about an Xcode project: its targets, configurations and where its sources are.
/// Read without running anything: `project.xcproj` (Xcode 27's JSON5) through XcodeProjectFormat,
/// and the older `project.pbxproj` (an ASCII property list) through `PropertyListSerialization`.
struct IDEXcodeProjectModel: Equatable, Sendable {
    enum Format: String, Sendable {
        /// `project.xcproj`, Xcode 27's JSON5 format.
        case xcproj
        /// `project.pbxproj`, the property-list format.
        case pbxproj
    }

    enum TargetKind: String, Sendable {
        case application
        case commandLineTool
        case framework
        case library
        case bundle
        case test
        case appExtension
        case other

        init(productType: String?) {
            switch productType {
            case "com.apple.product-type.application", "com.apple.product-type.application.on-demand-install-capable":
                self = .application
            case "com.apple.product-type.tool": self = .commandLineTool
            case "com.apple.product-type.framework", "com.apple.product-type.framework.static": self = .framework
            case "com.apple.product-type.library.static", "com.apple.product-type.library.dynamic": self = .library
            case "com.apple.product-type.bundle": self = .bundle
            case "com.apple.product-type.bundle.unit-test", "com.apple.product-type.bundle.ui-testing": self = .test
            case .some(let type) where type.hasPrefix("com.apple.product-type.app-extension"): self = .appExtension
            default: self = .other
            }
        }

        var systemImage: String {
            switch self {
            case .application: "macwindow"
            case .commandLineTool: "terminal"
            case .framework: "shippingbox"
            case .library: "books.vertical"
            case .bundle: "cube"
            case .test: "checkmark.seal"
            case .appExtension: "puzzlepiece.extension"
            case .other: "cube"
            }
        }
    }

    struct Target: Equatable, Sendable {
        var name: String
        var kind: TargetKind
        var productType: String?
    }

    /// `<root>/Name.xcodeproj`.
    var projectURL: URL
    var format: Format
    var targets: [Target]
    var configurations: [String]
    /// Standardized paths of the folders and groups that hold sources.
    var sourceDirectories: [URL]
    /// Swift packages the project depends on.
    var packageCount: Int

    var name: String { projectURL.deletingPathExtension().lastPathComponent }

    /// The files whose change means the model is stale.
    var definitionFile: URL {
        projectURL.appendingPathComponent(format == .xcproj ? "project.xcproj" : "project.pbxproj")
    }

    // MARK: - Finding

    /// The `.xcodeproj` directly inside `root`. With several, the one named like the folder, else
    /// the first by name.
    static func findProject(in root: URL, fileManager: FileManager = .default) -> URL? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        // Rebuilt from `root`: the listing hands back resolved paths (`/private/var…`), and the
        // project watcher's paths arrive in the root's own spelling.
        let projects = entries
            .filter { $0.pathExtension == "xcodeproj" }
            .map { root.appendingPathComponent($0.lastPathComponent, isDirectory: true) }
            .filter { hasDefinition($0, fileManager: fileManager) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return projects.first { $0.deletingPathExtension().lastPathComponent == root.lastPathComponent }
            ?? projects.first
    }

    private static func hasDefinition(_ project: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: project.appendingPathComponent("project.xcproj").path)
            || fileManager.fileExists(atPath: project.appendingPathComponent("project.pbxproj").path)
    }

    // MARK: - Loading

    enum LoadError: LocalizedError {
        case missing
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .missing: "The project has no project.xcproj or project.pbxproj."
            case .unreadable(let reason): reason
            }
        }
    }

    /// Reads the project. Prefers `project.xcproj` when both exist, as Xcode 27 does.
    static func load(projectURL: URL) throws -> IDEXcodeProjectModel {
        let xcproj = projectURL.appendingPathComponent("project.xcproj")
        let pbxproj = projectURL.appendingPathComponent("project.pbxproj")
        if let data = try? Data(contentsOf: xcproj) {
            do {
                return model(from: try XCSchema.Project(jsonRepresentation: data), projectURL: projectURL)
            } catch {
                throw LoadError.unreadable(error.localizedDescription)
            }
        }
        if let data = try? Data(contentsOf: pbxproj) {
            return try model(fromPBXProj: data, projectURL: projectURL)
        }
        throw LoadError.missing
    }

    // MARK: project.xcproj

    static func model(from project: XCSchema.Project, projectURL: URL) -> IDEXcodeProjectModel {
        let base = projectURL.deletingLastPathComponent()
        var directories: [URL] = []
        collectDirectories(in: project.topLevelReferences, parent: base, into: &directories)
        let targets = project.targets.map { target -> Target in
            let type = target.commonProperties.productTypeID?.rawValue
            return Target(name: target.name, kind: TargetKind(productType: type), productType: type)
        }
        return IDEXcodeProjectModel(
            projectURL: projectURL,
            format: .xcproj,
            targets: targets,
            configurations: project.configurations.map(\.name.name),
            sourceDirectories: directories,
            packageCount: project.packages.count
        )
    }

    /// Folders are file-system trees; a group's own path adds to its parent's.
    private static func collectDirectories(
        in references: [XCSchema.Reference], parent: URL, into result: inout [URL]
    ) {
        for reference in references {
            switch reference {
            case .folder(let folder):
                if let url = resolve(folder.path, parent: parent) { result.append(url) }
            case .group(let group):
                let next = resolve(group.path, parent: parent) ?? parent
                collectDirectories(in: group.children, parent: next, into: &result)
            case .fileReference, .variantGroup, .versionGroup:
                break
            }
        }
    }

    private static func resolve(_ path: XCSchema.FilePath, parent: URL) -> URL? {
        guard !path.path.isEmpty else { return nil }
        switch path.base {
        case .group, .project:
            return parent.appendingPathComponent(path.path, isDirectory: true).standardizedFileURL
        case .absolute:
            return URL(fileURLWithPath: path.path, isDirectory: true).standardizedFileURL
        case .sourceRoot, .developer, .buildProducts, .sdk:
            return nil
        }
    }

    // MARK: project.pbxproj

    static func model(fromPBXProj data: Data, projectURL: URL) throws -> IDEXcodeProjectModel {
        let root: [String: Any]
        do {
            guard let parsed = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw LoadError.unreadable("project.pbxproj is not a property list dictionary.")
            }
            root = parsed
        } catch let error as LoadError {
            throw error
        } catch {
            throw LoadError.unreadable("Couldn't read project.pbxproj.")
        }
        let objects = root["objects"] as? [String: [String: Any]] ?? [:]

        let targets = objects.values
            .filter { $0["isa"] as? String == "PBXNativeTarget" }
            .compactMap { object -> Target? in
                guard let name = object["name"] as? String else { return nil }
                let type = object["productType"] as? String
                return Target(name: name, kind: TargetKind(productType: type), productType: type)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let configurations = objects.values
            .filter { $0["isa"] as? String == "XCBuildConfiguration" }
            .compactMap { $0["name"] as? String }
        var seen = Set<String>()
        let uniqueConfigurations = configurations.sorted().filter { seen.insert($0).inserted }

        let base = projectURL.deletingLastPathComponent()
        let directories = objects.values
            .filter { $0["isa"] as? String == "PBXFileSystemSynchronizedRootGroup" }
            .compactMap { $0["path"] as? String }
            .map { base.appendingPathComponent($0, isDirectory: true).standardizedFileURL }
            .sorted { $0.path < $1.path }

        let packages = objects.values.filter {
            let isa = $0["isa"] as? String
            return isa == "XCRemoteSwiftPackageReference" || isa == "XCLocalSwiftPackageReference"
        }.count

        return IDEXcodeProjectModel(
            projectURL: projectURL,
            format: .pbxproj,
            targets: targets,
            configurations: uniqueConfigurations,
            sourceDirectories: directories,
            packageCount: packages
        )
    }
}
