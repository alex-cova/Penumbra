import Foundation
import JavaIntelligence
import Penumbra

/// Owns the Go to File index: walks the project off the main thread, labels each file with its
/// Gradle module, and republishes a fresh immutable `PaletteFileIndex` when files are added,
/// removed or the module layout changes. The previous snapshot keeps answering queries while a
/// rebuild runs, so typing in the palette never waits on the disk.
@MainActor
final class IDEPaletteFileIndexer {
    /// The current snapshot. Empty (never `nil`) before the first build so the palette's Files
    /// tab exists from the start.
    private(set) var index = PaletteFileIndex(entries: [])
    /// Called whenever ``index`` is replaced.
    var onIndexChanged: (@MainActor (PaletteFileIndex) -> Void)?

    private var root: URL?
    private var gradleModel: JavaGradleProjectModel?
    private var buildTask: Task<Void, Never>?
    private var generation = 0
    private var isBuilding = false

    private static let rebuildDebounce: Duration = .milliseconds(300)
    /// Above this many changed paths in one batch (a checkout, a big build) skip the per-path
    /// check and just rebuild.
    private static let batchRebuildThreshold = 500

    func setRoot(_ url: URL?) {
        root = url
        gradleModel = nil
        // Drop the previous project's files immediately instead of serving them until the walk ends.
        index = PaletteFileIndex(entries: [])
        onIndexChanged?(index)
        scheduleRebuild(after: .zero)
    }

    /// The module layout changed (a Gradle sync finished or was cleared).
    func setGradleModel(_ model: JavaGradleProjectModel?) {
        gradleModel = model
        scheduleRebuild(after: .zero)
    }

    /// Reacts to file-system changes: content edits are ignored, added or removed files rebuild.
    func handle(_ batch: IDEProjectWatcher.Batch) {
        guard let root else { return }
        // A build in flight may already have walked past the changed paths.
        if isBuilding {
            scheduleRebuild(after: Self.rebuildDebounce)
            return
        }
        if batch.paths.count > Self.batchRebuildThreshold || Self.filesChanged(in: batch, root: root, index: index) {
            scheduleRebuild(after: Self.rebuildDebounce)
        }
    }

    // MARK: - Rebuild

    private func scheduleRebuild(after delay: Duration) {
        buildTask?.cancel()
        generation += 1
        let generation = generation
        guard let root else {
            buildTask = nil
            isBuilding = false
            return
        }
        isBuilding = true
        let model = gradleModel
        buildTask = Task.detached(priority: .userInitiated) { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            let built = Self.buildIndex(root: root, model: model)
            guard !Task.isCancelled, let built else { return }
            await self?.publish(built, generation: generation)
        }
    }

    private func publish(_ built: PaletteFileIndex, generation: Int) {
        guard generation == self.generation else { return }
        index = built
        isBuilding = false
        onIndexChanged?(built)
    }

    // MARK: - Change detection

    /// Whether `batch` added or removed an indexed file. Runs on the main actor, but touches the
    /// disk only for paths the index can't already explain.
    private static func filesChanged(in batch: IDEProjectWatcher.Batch, root: URL, index: PaletteFileIndex) -> Bool {
        let rootPrefix = root.path + "/"
        var outputCache: [String: Bool] = [:]
        for path in batch.paths {
            guard path.hasPrefix(rootPrefix) else { continue }
            let relative = String(path.dropFirst(rootPrefix.count))
            let components = relative.split(separator: "/")
            if components.contains(where: { $0.hasPrefix(".") }) { continue }
            if isInsideBuildOutput(components: components, rootPath: root.path, cache: &outputCache) { continue }

            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            let known = index.entry(forPath: path) != nil
            if exists {
                // A directory's files report their own events; only a new file matters.
                if !isDirectory.boolValue, !known { return true }
            } else if known || index.hasEntries(underRelativeDirectory: relative) {
                return true
            }
        }
        return false
    }

    private static func isInsideBuildOutput(components: [Substring], rootPath: String, cache: inout [String: Bool]) -> Bool {
        var parent = rootPath
        for component in components.dropLast() {
            let name = String(component)
            if IDEProjectModel.ignoredDirectoryNames.contains(name) { return true }
            if buildOutputNames.contains(name) {
                let key = parent + "/" + name
                let isOutput = cache[key] ?? isBuildOutput(name: name, parentPath: parent)
                cache[key] = isOutput
                if isOutput { return true }
            }
            parent += "/" + name
        }
        return false
    }

    // MARK: - Walking

    nonisolated private static let buildOutputNames: Set<String> = ["build", "out", "target"]
    nonisolated private static let buildMarkers = [
        "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "pom.xml"
    ]

    /// `build`, `out` and `target` are generated output only next to a build script, so a real
    /// package or folder with one of those names in a plain project is still listed.
    nonisolated private static func isBuildOutput(name: String, parentPath: String) -> Bool {
        guard buildOutputNames.contains(name) else { return false }
        return buildMarkers.contains { FileManager.default.fileExists(atPath: parentPath + "/" + $0) }
    }

    nonisolated private static func buildIndex(root: URL, model: JavaGradleProjectModel?) -> PaletteFileIndex? {
        let rootPath = root.path
        let resolver = ModuleResolver(rootPath: rootPath, model: model)
        var entries: [PaletteFileIndex.Entry] = []
        walk(
            directory: root,
            path: rootPath,
            context: resolver.context(forDirectory: rootPath),
            rootPath: rootPath,
            resolver: resolver,
            entries: &entries
        )
        guard !Task.isCancelled else { return nil }
        entries.sort { $0.relativePath < $1.relativePath }
        return PaletteFileIndex(entries: entries)
    }

    nonisolated private static func walk(
        directory: URL,
        path: String,
        context: ModuleResolver.Context?,
        rootPath: String,
        resolver: ModuleResolver,
        entries: inout [PaletteFileIndex.Entry]
    ) {
        guard !Task.isCancelled,
              let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return }
        for child in children {
            let name = child.lastPathComponent
            if name.hasPrefix(".") { continue }
            let childPath = path + "/" + name
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if IDEProjectModel.ignoredDirectoryNames.contains(name) || isBuildOutput(name: name, parentPath: path) {
                    continue
                }
                walk(
                    directory: child,
                    path: childPath,
                    context: resolver.context(forDirectory: childPath) ?? context,
                    rootPath: rootPath,
                    resolver: resolver,
                    entries: &entries
                )
            } else {
                entries.append(makeEntry(url: child, name: name, directoryPath: path, rootPath: rootPath, context: context))
            }
        }
    }

    nonisolated private static func makeEntry(
        url: URL,
        name: String,
        directoryPath: String,
        rootPath: String,
        context: ModuleResolver.Context?
    ) -> PaletteFileIndex.Entry {
        let relativeDirectory = directoryPath.count > rootPath.count ? String(directoryPath.dropFirst(rootPath.count + 1)) : ""
        let relativePath = relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
        let base = context?.moduleDirectory ?? rootPath
        let location: String
        if directoryPath == base {
            location = "."
        } else if directoryPath.hasPrefix(base + "/") {
            location = String(directoryPath.dropFirst(base.count + 1))
        } else {
            location = relativeDirectory.isEmpty ? "." : relativeDirectory
        }
        return PaletteFileIndex.Entry(
            url: url,
            relativePath: relativePath,
            location: location,
            module: context?.name,
            icon: IDEFileIcon.paletteIcon(forFilename: name)
        )
    }

    // MARK: - Modules

    /// Maps a directory to its IntelliJ-style module label (`root.sub.main`) using the synced
    /// Gradle model. Built once per index build; lookups are prefix checks over a handful of
    /// modules, and only run per directory rather than per file.
    struct ModuleResolver: Sendable {
        struct Context: Sendable {
            /// `sxb-gateway.main` inside a source set, `sxb-gateway` elsewhere in the module.
            let name: String
            /// Module directory in the walk's path space; the location column is relative to it.
            let moduleDirectory: String
        }

        private struct Module: Sendable {
            let directory: String
            let name: String
            let sourceDirectories: [(path: String, sourceSet: String)]
        }

        private let modules: [Module]

        init(rootPath: String, model: JavaGradleProjectModel?) {
            guard let model else {
                modules = []
                return
            }
            let resolvedRoot = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path
            // Gradle reports resolved paths; the walk uses the root exactly as the user opened it.
            func toWalkSpace(_ url: URL) -> String {
                let path = url.resolvingSymlinksInPath().path
                guard resolvedRoot != rootPath, path == resolvedRoot || path.hasPrefix(resolvedRoot + "/") else { return path }
                return rootPath + path.dropFirst(resolvedRoot.count)
            }
            let rootName = model.subprojects.first { $0.path == ":" }?.directory.lastPathComponent
                ?? URL(fileURLWithPath: rootPath).lastPathComponent
            modules = model.subprojects.map { subproject in
                let components = [rootName] + subproject.path.split(separator: ":").map(String.init)
                return Module(
                    directory: toWalkSpace(subproject.directory),
                    name: components.joined(separator: "."),
                    sourceDirectories: subproject.sourceSets.flatMap { set in
                        set.sourceDirs.map { (path: toWalkSpace($0), sourceSet: set.name) }
                    }
                )
            }
            .sorted { $0.directory.count > $1.directory.count }
        }

        func context(forDirectory path: String) -> Context? {
            guard let module = modules.first(where: { path == $0.directory || path.hasPrefix($0.directory + "/") }) else {
                return nil
            }
            var sourceSet: String?
            var bestLength = -1
            for source in module.sourceDirectories
            where (path == source.path || path.hasPrefix(source.path + "/")) && source.path.count > bestLength {
                sourceSet = source.sourceSet
                bestLength = source.path.count
            }
            if sourceSet == nil {
                // Resource folders (`src/main/resources`) aren't Java source dirs but belong to the set.
                let sourcePrefix = module.directory + "/src/"
                if path.hasPrefix(sourcePrefix) {
                    sourceSet = path.dropFirst(sourcePrefix.count).split(separator: "/").first.map(String.init)
                }
            }
            return Context(
                name: sourceSet.map { module.name + "." + $0 } ?? module.name,
                moduleDirectory: module.directory
            )
        }
    }
}
