import Foundation
import JavaIntelligence
import Observation

/// One row of the Explorer's External Libraries section.
struct IDEExternalLibraryItem: Identifiable, Equatable {
    enum Kind {
        case section, jdk, library, module, package, folder, type, resource, message
    }

    let id: String
    let kind: Kind
    let title: String
    var subtitle: String?
    /// Below the section row (0).
    let depth: Int
    var canDisclose: Bool
    var isExpanded: Bool
    /// `org.slf4j.Logger` for a `.type`.
    var qualifiedName: String?
    /// The jar a `.resource` lives in, and its entry name.
    var archive: URL?
    var entry: String?
    /// The jar of a library row or the home of the JDK, for Reveal in Finder and Copy Path.
    var location: URL?
    /// A root row of the Opened Archives section (a jar the user opened), which can be closed.
    var isOpenedArchive = false

    var isOpenable: Bool { kind == .type || kind == .resource }
}

/// State of a window's External Libraries section: the project's dependency jars, which rows are open
/// and what each opened jar holds. A jar's tree is read from its central directory on first
/// expansion, off the main actor; nothing is read for a library nobody opens.
@MainActor
@Observable
final class IDEExternalLibrariesModel {
    static let sectionID = "libsection"
    static let archivesSectionID = "archivesection"
    private static let archivePrefix = "archive:"
    /// Separates a library's id from a node id inside `expandedIDs` and `contents`.
    private static let separator = "\u{1F}"

    private(set) var libraries: [JavaExternalLibrary] = []
    /// Jars opened on their own (File ▸ Open, the Explorer, Finder), listed in the order they were
    /// opened. They are not part of the project's classpath; their rows are read the same way.
    private(set) var openedArchives: [URL] = []
    private(set) var expandedIDs: Set<String> = []
    /// Row currently highlighted. Never a project file path, so it can sit beside `selectedPath`.
    var selectedID: String?

    /// The JDK of the open project, asked while rows are built so the section follows a JDK change.
    @ObservationIgnored var jdkProvider: @MainActor () -> JDKInstallation? = { nil }

    private(set) var contents: [String: [JavaArchiveNode]] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var generation = 0

    private enum Source {
        case jar(URL)
        case jdk(JDKInstallation)
    }

    var isEmpty: Bool { libraries.isEmpty && jdkProvider() == nil && openedArchives.isEmpty }
    var hasOpenedArchives: Bool { !openedArchives.isEmpty }

    static func archiveID(for url: URL) -> String { archivePrefix + url.standardizedFileURL.path }

    // MARK: - Opened archives

    /// Adds `url` to the Opened Archives section, expanded, and returns its row id. A jar that is
    /// already there is only selected and expanded again.
    @discardableResult
    func openArchive(_ url: URL) -> String {
        let standard = url.standardizedFileURL
        let id = Self.archiveID(for: standard)
        if !openedArchives.contains(standard) { openedArchives.append(standard) }
        expandedIDs.insert(Self.archivesSectionID)
        expandedIDs.insert(id)
        selectedID = id
        loadMissingContents()
        return id
    }

    func closeArchive(_ url: URL) {
        let standard = url.standardizedFileURL
        let id = Self.archiveID(for: standard)
        openedArchives.removeAll { $0 == standard }
        contents[id] = nil
        loading.remove(id)
        expandedIDs = expandedIDs.filter { $0.components(separatedBy: Self.separator)[0] != id }
        if let selectedID, selectedID.components(separatedBy: Self.separator)[0] == id { self.selectedID = nil }
    }

    // MARK: - Updating

    func update(libraries newLibraries: [JavaExternalLibrary]) {
        guard newLibraries != libraries else { return }
        libraries = newLibraries
        generation += 1
        loading.removeAll()
        let live = Set(newLibraries.map(\.id))
        func isLive(_ key: String) -> Bool {
            let root = key.components(separatedBy: Self.separator)[0]
            return root == Self.sectionID || root == Self.archivesSectionID
                || root.hasPrefix(Self.jdkPrefix) || root.hasPrefix(Self.archivePrefix) || live.contains(root)
        }
        contents = contents.filter { isLive($0.key) }
        expandedIDs = expandedIDs.filter(isLive)
        if let selectedID, !isLive(selectedID) { self.selectedID = nil }
        loadMissingContents()
    }

    /// Forgets the project's libraries. Archives the user opened stay, with their trees.
    func clear() {
        generation += 1
        loading.removeAll()
        libraries = []
        func isArchive(_ key: String) -> Bool {
            let root = key.components(separatedBy: Self.separator)[0]
            return root == Self.archivesSectionID || root.hasPrefix(Self.archivePrefix)
        }
        contents = contents.filter { isArchive($0.key) }
        expandedIDs = expandedIDs.filter(isArchive)
        if let selectedID, !isArchive(selectedID) { self.selectedID = nil }
        loadMissingContents()
    }

    // MARK: - Expansion

    func isExpanded(_ id: String) -> Bool { expandedIDs.contains(id) }

    func toggle(_ id: String) {
        if !expandedIDs.insert(id).inserted { expandedIDs.remove(id) }
        loadMissingContents()
    }

    func expand(_ id: String) {
        expandedIDs.insert(id)
        loadMissingContents()
    }

    func collapse(_ id: String) { expandedIDs.remove(id) }

    // MARK: - Rows

    private static let jdkPrefix = "jdk:"

    /// The section as Explorer rows. With a `filter`, a library or JDK stays when its name matches or
    /// something inside it that is already open does; only open branches are searched, so a filter
    /// never makes a jar load.
    func rows(filter: String = "", includesProjectLibraries: Bool = true) -> [IDEExternalLibraryItem] {
        (includesProjectLibraries ? projectRows(filter: filter) : []) + archiveRows(filter: filter)
    }

    /// The Opened Archives section: one root per jar the user opened.
    private func archiveRows(filter: String) -> [IDEExternalLibraryItem] {
        guard !openedArchives.isEmpty else { return [] }
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtering = !needle.isEmpty
        var roots: [IDEExternalLibraryItem] = []
        for url in openedArchives {
            appendRoot(
                &roots, id: Self.archiveID(for: url), kind: .library, title: url.lastPathComponent,
                subtitle: nil, archive: url, location: url, needle: needle, standalone: true
            )
        }
        if filtering && roots.isEmpty { return [] }
        let expanded = filtering || isExpanded(Self.archivesSectionID)
        let section = IDEExternalLibraryItem(
            id: Self.archivesSectionID, kind: .section, title: "Opened Archives", subtitle: nil, depth: 0,
            canDisclose: true, isExpanded: expanded
        )
        return expanded ? [section] + roots : [section]
    }

    private func projectRows(filter: String) -> [IDEExternalLibraryItem] {
        let jdk = jdkProvider()
        guard jdk != nil || !libraries.isEmpty else { return [] }
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtering = !needle.isEmpty
        var roots: [IDEExternalLibraryItem] = []

        if let jdk {
            let id = Self.jdkPrefix + jdk.home.path
            appendRoot(
                &roots, id: id, kind: .jdk, title: "JDK \(jdk.featureVersion)",
                subtitle: jdk.vendor ?? jdk.versionString, archive: nil, location: jdk.home, needle: needle
            )
        }
        for library in libraries {
            appendRoot(
                &roots, id: library.id, kind: .library, title: library.label,
                subtitle: nil, archive: library.jar, location: library.jar, needle: needle
            )
        }

        if filtering && roots.isEmpty { return [] }
        let expanded = filtering || isExpanded(Self.sectionID)
        let section = IDEExternalLibraryItem(
            id: Self.sectionID, kind: .section, title: "External Libraries", subtitle: nil, depth: 0,
            canDisclose: true, isExpanded: expanded
        )
        return expanded ? [section] + roots : [section]
    }

    /// A root row plus, when it is open, its tree. In filter mode nothing is added unless the root or
    /// a loaded descendant matches.
    private func appendRoot(
        _ rows: inout [IDEExternalLibraryItem], id: String, kind: IDEExternalLibraryItem.Kind,
        title: String, subtitle: String?, archive: URL?, location: URL, needle: String,
        standalone: Bool = false
    ) {
        let open = isExpanded(id)
        var branch: [IDEExternalLibraryItem] = []
        if open {
            if let nodes = contents[id] {
                if nodes.isEmpty {
                    branch.append(message(kind == .jdk ? "No sources available" : "Empty", depth: 2))
                } else {
                    branch = items(for: nodes, rootID: id, archive: archive, depth: 2, needle: needle, standalone: standalone)
                }
            } else {
                branch.append(message("Loading…", depth: 2))
            }
        }
        let titleMatches = needle.isEmpty || Self.matches(title, needle)
        guard titleMatches || !branch.filter({ $0.kind != .message }).isEmpty else { return }
        var root = IDEExternalLibraryItem(
            id: id, kind: kind, title: title, subtitle: subtitle, depth: 1, canDisclose: true, isExpanded: open,
            location: location
        )
        root.isOpenedArchive = standalone
        rows.append(root)
        // A library whose own name matched shows its whole open tree, not a filtered part of it.
        if open {
            rows.append(contentsOf: titleMatches && !needle.isEmpty && contents[id] != nil
                ? items(for: contents[id] ?? [], rootID: id, archive: archive, depth: 2, needle: "", standalone: standalone)
                : branch)
        }
    }

    private func message(_ text: String, depth: Int) -> IDEExternalLibraryItem {
        IDEExternalLibraryItem(
            id: "libmessage:\(depth):\(text)", kind: .message, title: text, depth: depth,
            canDisclose: false, isExpanded: false
        )
    }

    private func items(
        for nodes: [JavaArchiveNode], rootID: String, archive: URL?, depth: Int, needle: String,
        standalone: Bool = false
    ) -> [IDEExternalLibraryItem] {
        var result: [IDEExternalLibraryItem] = []
        for node in nodes {
            let key = rootID + Self.separator + node.id
            let hasChildren = !node.children.isEmpty
            let open = hasChildren && isExpanded(key)
            let children = open ? items(for: node.children, rootID: rootID, archive: archive, depth: depth + 1, needle: needle, standalone: standalone) : []
            if !needle.isEmpty, !Self.matches(node.name, needle), children.isEmpty { continue }
            result.append(IDEExternalLibraryItem(
                id: key, kind: Self.kind(of: node.kind), title: node.name, depth: depth,
                canDisclose: hasChildren, isExpanded: open,
                qualifiedName: node.qualifiedName,
                // A project library's class opens through the index; a standalone jar's has no index,
                // so its row carries the jar and entry to extract.
                archive: node.kind == .resource || (standalone && node.kind == .type) ? archive : nil,
                entry: node.entry
            ))
            result.append(contentsOf: children)
        }
        return result
    }

    private static func kind(of kind: JavaArchiveNode.Kind) -> IDEExternalLibraryItem.Kind {
        switch kind {
        case .module: .module
        case .package: .package
        case .folder: .folder
        case .type: .type
        case .resource: .resource
        }
    }

    private static func matches(_ name: String, _ needle: String) -> Bool {
        name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    // MARK: - Loading

    /// Starts reading every open library or JDK whose tree is not there yet.
    func loadMissingContents() {
        for library in libraries where isExpanded(library.id) {
            load(rootID: library.id, source: .jar(library.jar))
        }
        for url in openedArchives where isExpanded(Self.archiveID(for: url)) {
            load(rootID: Self.archiveID(for: url), source: .jar(url))
        }
        if let jdk = jdkProvider(), isExpanded(Self.jdkPrefix + jdk.home.path) {
            load(rootID: Self.jdkPrefix + jdk.home.path, source: .jdk(jdk))
        }
    }

    private func load(rootID: String, source: Source) {
        guard contents[rootID] == nil, loading.insert(rootID).inserted else { return }
        let generation = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let nodes = Self.read(source)
            await MainActor.run {
                guard let self, self.generation == generation else { return }
                self.loading.remove(rootID)
                self.contents[rootID] = nodes
            }
        }
    }

    nonisolated private static func read(_ source: Source) -> [JavaArchiveNode] {
        switch source {
        case .jar(let url):
            guard let archive = try? ZipArchive(url: url) else { return [] }
            return JavaArchiveContents.nodes(entries: archive.entries.map(\.name), layout: .jar)
        case .jdk(let jdk):
            // Sources read best; `jmods` still lists the classes of a JDK installed without them.
            // A JDK 8 `src.zip` has no module folders.
            if jdk.featureVersion >= 9, let archive = try? ZipArchive(url: jdk.srcZip) {
                return JavaArchiveContents.nodes(entries: archive.entries.map(\.name), layout: .moduleRooted)
            }
            let files = (try? FileManager.default.contentsOfDirectory(at: jdk.jmodsDir, includingPropertiesForKeys: nil)) ?? []
            var names: [String] = []
            for file in files where file.pathExtension == "jmod" {
                guard let archive = try? ZipArchive(url: file) else { continue }
                let module = file.deletingPathExtension().lastPathComponent
                for entry in archive.entries where entry.name.hasPrefix("classes/") {
                    names.append(module + "/" + entry.name.dropFirst("classes/".count))
                }
            }
            return JavaArchiveContents.nodes(entries: names, layout: .moduleRooted)
        }
    }
}
