import Foundation
import JavaIntelligence

/// Keeps a ``SpringProjectModel`` filled for the modules ``SpringProjectDetector`` found.
///
/// It does nothing for a project without Spring: `configure` finds no modules, empties the store and
/// no file is ever read. For a Spring project it walks the main source roots once in the background
/// (cancellable, skipping files whose size and modification date are unchanged) and then follows
/// open-buffer edits through ``ingest(url:text:)``.
public actor SpringWorkspaceIndexer {
    public nonisolated let store: SpringProjectModel
    public private(set) var modules: [SpringModuleInfo] = []
    private var stamps: [URL: Stamp] = [:]
    private var scan: Task<Void, Never>?
    private var scanGeneration = 0
    private let metadataLoader = SpringMetadataLoader()
    private var configStamps: [URL: Stamp] = [:]

    private struct Stamp: Equatable { let size: Int; let modified: Date }

    public init(store: SpringProjectModel = SpringProjectModel()) { self.store = store }

    /// Test seam: declare the modules without a build model (the store already holds the sources).
    public func configureForTesting(modules: [SpringModuleInfo]) async {
        self.modules = modules
        await store.setModules(modules)
    }

    public var isActive: Bool { modules.contains { $0.isSpring } }

    /// Whether `url` is an `application*` file under a Spring module's resources, or a file one of them imports.
    public func containsConfig(_ url: URL) async -> Bool {
        let u = url.standardizedFileURL
        guard SpringConfigFileName.parse(u.lastPathComponent) != nil else { return await store.configFileURLs().contains(u) }
        let path = u.path
        return modules.filter(\.isSpring).contains { m in
            (m.resourceRoots + [m.directory]).contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
        }
    }

    public func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return modules.filter(\.isSpring).contains { $0.sourceRoots.contains { path.hasPrefix($0.standardizedFileURL.path + "/") } }
    }

    /// Re-detects from the build model. `nil` (not synced yet) leaves the current state alone.
    public func configure(model: JavaGradleProjectModel?) async {
        guard let model else { return }
        let found = SpringProjectDetector.detect(in: model)
        guard found != modules else { return }
        modules = found
        await store.setModules(found)
        scan?.cancel()
        let loader = metadataLoader
        let store = self.store
        let moduleSnapshot = found
        scanGeneration += 1
        guard !found.isEmpty else {
            stamps = [:]; configStamps = [:]
            await store.removeAll()
            return
        }
        let generation = scanGeneration
        let roots = found.flatMap(\.sourceRoots)
        scan = Task { [weak self] in
            await self?.scanRoots(roots, generation: generation)
            await self?.scanConfig(generation: generation)
            // Library metadata is read after the sources so the editor is usable first; it is cached per jar.
            let metadata = await loader.load(modules: moduleSnapshot)
            if !Task.isCancelled { await store.setExternalMetadata(metadata, resourceRoots: moduleSnapshot.flatMap(\.resourceRoots)) }
        }
    }

    /// Forgets everything (project closed, or no build model any more).
    public func reset() async {
        scan?.cancel(); scanGeneration += 1
        modules = []; stamps = [:]; configStamps = [:]
        await store.setModules([])
        await store.removeAll()
    }

    /// Re-reads files whose size or modification date changed on disk (a cheap stat walk).
    public func rescan() {
        guard isActive else { return }
        scan?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        let roots = modules.flatMap(\.sourceRoots)
        scan = Task { [weak self] in
            await self?.scanRoots(roots, generation: generation)
            await self?.scanConfig(generation: generation)
        }
    }

    /// Waits for the current background scan (tests and "reveal in tool window" readiness).
    public func waitForScan() async { await scan?.value }

    /// An open buffer's text, which wins over the file on disk.
    @discardableResult
    public func ingest(url: URL, text: String) async -> Bool {
        if url.pathExtension != "java" {
            guard await containsConfig(url) else { return false }
            configStamps[url.standardizedFileURL] = nil
            return await store.updateConfig(url: url.standardizedFileURL, text: text, allowAnyName: true)
        }
        guard contains(url) else { return false }
        stamps[url.standardizedFileURL] = nil   // the disk copy no longer describes the buffer
        return await store.update(url: url.standardizedFileURL, source: text)
    }

    public func fileRemoved(_ url: URL) async {
        stamps[url.standardizedFileURL] = nil
        await store.remove(url: url.standardizedFileURL)
    }

    /// `application*` files directly in each resource root and its `config/` folder, then the files they import.
    private func scanConfig(generation: Int) async {
        let fm = FileManager.default
        await store.setResourceRoots(modules.flatMap(\.resourceRoots))
        var found: [URL] = []
        for module in modules where module.isSpring {
            for root in module.resourceRoots {
                for dir in [root, root.appendingPathComponent("config", isDirectory: true)] {
                    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where SpringConfigFileName.parse(name) != nil {
                        found.append(dir.appendingPathComponent(name).standardizedFileURL)
                    }
                }
            }
        }
        var seen = Set<URL>()
        var queue = found, depth = 0
        while !queue.isEmpty, depth < 4 {
            var next: [URL] = []
            for url in queue where seen.insert(url).inserted {
                if Task.isCancelled || generation != scanGeneration { return }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let stamp = Stamp(size: values?.fileSize ?? -1, modified: values?.contentModificationDate ?? .distantPast)
                if configStamps[url] != stamp, let text = try? String(contentsOf: url, encoding: .utf8) {
                    configStamps[url] = stamp
                    await store.updateConfig(url: url, text: text, allowAnyName: true)
                }
                let model = await store.config()
                for e in model.file(at: url)?.entries ?? [] where e.key == "spring.config.import" {
                    for item in (e.value ?? "").split(separator: ",") {
                        if let target = model.resolveImport(item.trimmingCharacters(in: .whitespaces), from: url),
                           fm.fileExists(atPath: target.path) { next.append(target) }
                    }
                }
            }
            queue = next
            depth += 1
        }
        for url in await store.configFileURLs() where !seen.contains(url) && configStamps[url] != nil {
            configStamps[url] = nil
            await store.removeConfig(url: url)
        }
    }

    private func scanRoots(_ roots: [URL], generation: Int) async {
        let fm = FileManager.default
        var seen = Set<URL>()
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { continue }
            while let item = walker.nextObject() as? URL {
                if Task.isCancelled || generation != scanGeneration { return }
                guard item.pathExtension == "java" else { continue }
                let url = item.standardizedFileURL
                seen.insert(url)
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let stamp = Stamp(size: values?.fileSize ?? -1, modified: values?.contentModificationDate ?? .distantPast)
                if stamps[url] == stamp { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                stamps[url] = stamp
                await store.update(url: url, source: text)
                await Task.yield()
            }
        }
        // Files that vanished since the last scan.
        for url in stamps.keys where !seen.contains(url) {
            stamps[url] = nil
            await store.remove(url: url)
        }
    }
}
