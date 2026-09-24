import Foundation

/// Discovers JUnit tests across a Gradle model's test source sets. Scan results are cached per
/// file by ``JavaStamp`` (size + mtime); an open editor buffer can override a file's disk content.
public actor JavaTestDiscovery {
    private struct SetKey: Hashable {
        let subprojectPath: String
        let sourceSetName: String
    }

    private struct CacheKey: Hashable {
        let url: URL
        let frameworks: Set<JavaTestFramework>
    }

    private enum Source: Hashable {
        case disk(JavaStamp)
        case buffer(Int)
    }

    private struct CacheEntry {
        let source: Source
        let classes: [JavaTestClass]
    }

    private static let maxConcurrentScans = 4

    private var model: JavaGradleProjectModel
    private var files: [SetKey: Set<URL>] = [:]
    private var cache: [CacheKey: CacheEntry] = [:]
    private var buffers: [URL: String] = [:]
    /// Number of files actually parsed so far (cache hits do not count).
    public private(set) var scanCount = 0

    public init(model: JavaGradleProjectModel) {
        self.model = model
    }

    /// Replaces the model (after a sync). Call ``discover()`` afterwards to re-walk the source dirs.
    public func setModel(_ model: JavaGradleProjectModel) {
        self.model = model
    }

    /// The text of an open buffer, used in place of the file on disk; `nil` drops the override.
    /// Call ``update(files:)`` to apply it.
    public func setBufferText(_ text: String?, for url: URL) {
        buffers[Self.normalized(url)] = text
    }

    /// Walks every test source set's directories, scans new or changed files, drops vanished ones.
    public func discover() async -> JavaTestTree {
        var found: [SetKey: Set<URL>] = [:]
        for ref in model.testSourceSetRefs {
            var urls = Set<URL>()
            for dir in ref.sourceSet.sourceDirs where FileManager.default.fileExists(atPath: dir.path) {
                for url in SourceRoot(directory: dir).javaFileURLs() { urls.insert(Self.normalized(url)) }
            }
            for url in buffers.keys where Self.isInside(url, dirs: ref.sourceSet.sourceDirs) { urls.insert(url) }
            found[SetKey(subprojectPath: ref.subprojectPath, sourceSetName: ref.sourceSet.name)] = urls
        }
        files = found
        await scanMissing()
        return currentTree()
    }

    /// Rescans the given files (changed on disk or in a buffer). A file that no longer exists and
    /// has no buffer is removed; a new file inside a test source directory is added.
    public func update(files urls: [URL]) async -> JavaTestTree {
        let urls = urls.map(Self.normalized)
        for ref in model.testSourceSetRefs {
            let key = SetKey(subprojectPath: ref.subprojectPath, sourceSetName: ref.sourceSet.name)
            for url in urls where url.pathExtension == "java" && Self.isInside(url, dirs: ref.sourceSet.sourceDirs) {
                if buffers[url] != nil || FileManager.default.fileExists(atPath: url.path) {
                    files[key, default: []].insert(url)
                } else {
                    files[key]?.remove(url)
                }
            }
        }
        await scanMissing()
        return currentTree()
    }

    /// Forgets files (deleted or moved) and their cached results.
    public func remove(files urls: [URL]) -> JavaTestTree {
        let urls = Set(urls.map(Self.normalized))
        for key in files.keys { files[key]?.subtract(urls) }
        for key in cache.keys where urls.contains(key.url) { cache[key] = nil }
        return currentTree()
    }

    /// The tree from what has been scanned so far, without touching the disk.
    public func currentTree() -> JavaTestTree {
        var subprojects: [JavaTestSubprojectNode] = []
        for sub in model.subprojects {
            var nodes: [JavaTestSourceSetNode] = []
            for set in sub.testSourceSets {
                let frameworks = JavaTestFramework.detect(in: set)
                var entries: [JavaTestClassEntry] = []
                for url in files[SetKey(subprojectPath: sub.path, sourceSetName: set.name)] ?? [] {
                    guard let entry = cache[CacheKey(url: url, frameworks: frameworks)] else { continue }
                    for cls in entry.classes where !cls.isAbstract {
                        entries.append(JavaTestClassEntry(fileURL: url, testClass: cls))
                    }
                }
                entries.sort { ($0.testClass.binaryName, $0.fileURL.path) < ($1.testClass.binaryName, $1.fileURL.path) }
                nodes.append(JavaTestSourceSetNode(name: set.name, frameworks: frameworks, classes: entries))
            }
            if !nodes.isEmpty {
                subprojects.append(JavaTestSubprojectNode(path: sub.path, directory: sub.directory, sourceSets: nodes))
            }
        }
        return JavaTestTree(subprojects: subprojects)
    }

    // MARK: Scanning

    private struct Job {
        let key: CacheKey
        let source: Source
        let text: String?
    }

    private func scanMissing() async {
        var jobs: [Job] = []
        var wanted = Set<CacheKey>()
        for ref in model.testSourceSetRefs {
            let frameworks = JavaTestFramework.detect(in: ref.sourceSet)
            let setKey = SetKey(subprojectPath: ref.subprojectPath, sourceSetName: ref.sourceSet.name)
            for url in files[setKey] ?? [] {
                let key = CacheKey(url: url, frameworks: frameworks)
                guard wanted.insert(key).inserted else { continue }
                let source: Source
                var text: String?
                if let buffer = buffers[url] {
                    source = .buffer(buffer.hashValue)
                    text = buffer
                } else if let stamp = JavaStamp(url: URL(fileURLWithPath: url.path)) { // fresh URL: resource values are cached per instance
                    source = .disk(stamp)
                } else {
                    continue
                }
                if cache[key]?.source == source { continue }
                jobs.append(Job(key: key, source: source, text: text))
            }
        }

        var results: [(Job, [JavaTestClass])] = []
        await withTaskGroup(of: (Job, [JavaTestClass])?.self) { group in
            var iterator = jobs.makeIterator()
            var running = 0
            func addNext(_ group: inout TaskGroup<(Job, [JavaTestClass])?>) {
                guard let job = iterator.next() else { return }
                running += 1
                group.addTask { Self.scan(job) }
            }
            for _ in 0..<Self.maxConcurrentScans { addNext(&group) }
            while let outcome = await group.next() {
                running -= 1
                if let outcome { results.append(outcome) }
                addNext(&group)
            }
        }
        for (job, classes) in results {
            cache[job.key] = CacheEntry(source: job.source, classes: classes)
            scanCount += 1
        }
        // Drop entries for files that left every source set.
        let live = Set(files.flatMap { key, urls in urls.map { ($0, key) } }.map(\.0))
        for key in cache.keys where !live.contains(key.url) { cache[key] = nil }
    }

    private nonisolated static func scan(_ job: Job) -> (Job, [JavaTestClass])? {
        let text = job.text ?? (try? String(contentsOf: job.key.url, encoding: .utf8))
        guard let text else { return nil }
        return (job, JavaTestScanner.scan(source: text, url: job.key.url, frameworks: job.key.frameworks))
    }

    // MARK: Paths

    private nonisolated static func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private nonisolated static func isInside(_ url: URL, dirs: [URL]) -> Bool {
        dirs.contains { dir in
            let prefix = normalized(dir).path
            return url.path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
        }
    }
}
