import Foundation
import Observation

/// What the wizard remembers between runs. Kept on this Mac in `UserDefaults`, outside the
/// preferences snapshot, like the other per-machine choices.
enum IDENewProjectDefaults {
    private static let templateKey = "umbra.newProject.template"
    private static let organizationKey = "umbra.newProject.organization"
    private static let locationKey = "umbra.newProject.location"

    static var templateID: String? {
        get { UserDefaults.standard.string(forKey: templateKey) }
        set { UserDefaults.standard.set(newValue, forKey: templateKey) }
    }

    static var organizationIdentifier: String {
        get { UserDefaults.standard.string(forKey: organizationKey) ?? "com.example" }
        set { UserDefaults.standard.set(newValue, forKey: organizationKey) }
    }

    /// The last parent folder, only while it still exists and can be written. In a sandbox a
    /// folder the user has not granted this session reads as not writable, so the field stays
    /// empty and the user picks one.
    static var location: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: locationKey) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue, FileManager.default.isWritableFile(atPath: path)
            else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: locationKey) }
    }
}

/// "Open this file once the new project is a window's folder". Every way of opening a folder ends
/// in `IDEWorkspace.openProjectFolder`, which takes the request for its root; the window that gets
/// the folder (this one, a replaced one or a new one) is not known when the project is created.
@MainActor
enum IDENewProjectOpenRequests {
    private static var requests: [String: String] = [:]

    static func register(root: URL, relativePath: String) {
        requests[key(root)] = relativePath
    }

    /// The file to open for `root`, once.
    static func take(for root: URL) -> URL? {
        guard let relative = requests.removeValue(forKey: key(root)) else { return nil }
        return root.appendingPathComponent(relative)
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// The file preview's rows: folders first at every level, so a leaf is never shown without the
/// folders it sits in.
enum IDENewProjectTree {
    struct Row: Equatable, Identifiable {
        var path: String
        var name: String
        var depth: Int
        var isDirectory: Bool
        var id: String { path }
    }

    static func rows(paths: [String]) -> [Row] {
        final class Node {
            var directories: [String: Node] = [:]
            var files: [String] = []
        }
        let root = Node()
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard let file = components.last else { continue }
            var node = root
            for component in components.dropLast() {
                if let existing = node.directories[component] {
                    node = existing
                } else {
                    let created = Node()
                    node.directories[component] = created
                    node = created
                }
            }
            node.files.append(file)
        }
        var rows: [Row] = []
        func walk(_ node: Node, prefix: String, depth: Int) {
            for name in node.directories.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let path = prefix + name
                rows.append(Row(path: path, name: name, depth: depth, isDirectory: true))
                walk(node.directories[name]!, prefix: path + "/", depth: depth + 1)
            }
            for name in node.files.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                rows.append(Row(path: prefix + name, name: name, depth: depth, isDirectory: false))
            }
        }
        walk(root, prefix: "", depth: 0)
        return rows
    }
}

/// The New Project sheet's state.
@MainActor
@Observable
final class IDENewProjectModel {
    var templateID: String
    var name: String
    var organizationIdentifier: String
    var minimumMacOS: String
    var parentDirectory: URL?
    private(set) var isCreating = false
    private(set) var errorMessage: String?

    static let macOSVersions = ["26.0", "15.0", "14.0", "13.0", "12.0"]

    init() {
        let remembered = IDENewProjectDefaults.templateID.flatMap(IDEProjectTemplates.template(id:))
        templateID = (remembered ?? IDEProjectTemplates.all[0]).id
        name = "MyProject"
        organizationIdentifier = IDENewProjectDefaults.organizationIdentifier
        minimumMacOS = "15.0"
        parentDirectory = IDENewProjectDefaults.location
    }

    var template: any IDEProjectTemplate {
        IDEProjectTemplates.template(id: templateID) ?? IDEProjectTemplates.all[0]
    }

    var options: IDENewProjectOptions {
        var options = IDENewProjectOptions(
            name: name,
            parentDirectory: parentDirectory ?? URL(fileURLWithPath: "/", isDirectory: true)
        )
        options.organizationIdentifier = organizationIdentifier
        options.minimumMacOS = minimumMacOS
        return options
    }

    var issues: [IDENewProjectIssue] {
        var found = IDENewProjectValidator.issues(for: options, template: template)
        if parentDirectory == nil, !found.contains(.noLocation) { found.append(.noLocation) }
        return found
    }

    var canCreate: Bool { issues.isEmpty && !isCreating }

    /// Relative paths the template would write, sorted, for the preview.
    var previewPaths: [String] {
        ((try? template.files(for: options)) ?? []).map(\.path).sorted()
    }

    /// The preview as a tree: folders, then files, nested.
    var previewRows: [IDENewProjectTree.Row] {
        IDENewProjectTree.rows(paths: previewPaths)
    }

    /// Writes the project and returns its root, or nil with `errorMessage` set.
    func create() async -> (root: URL, template: any IDEProjectTemplate, options: IDENewProjectOptions)? {
        guard canCreate else { return nil }
        let template = template
        let options = options
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            let root = try await Task.detached(priority: .userInitiated) {
                try IDEProjectWriter.create(template, options: options)
            }.value
            IDENewProjectDefaults.templateID = template.id
            IDENewProjectDefaults.organizationIdentifier = options.organizationIdentifier
            IDENewProjectDefaults.location = options.parentDirectory
            return (root, template, options)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
