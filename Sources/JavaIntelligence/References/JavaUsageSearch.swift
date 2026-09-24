import Foundation

/// Project-wide usage search: narrow the roots to the source sets that can see the symbol, ask a
/// candidate source which files mention its name, then resolve each candidate file.
public enum JavaUsageSearch {
    /// Streams usages as files finish (order across files is not defined; use ``collect`` for a
    /// sorted list). Cancelling the consuming task, or dropping the stream, stops the work.
    ///
    /// - Parameters:
    ///   - roots: every project source root (or file); narrowed by ``scopedRoots`` when a Gradle
    ///     model is in the environment.
    ///   - includeDeclarations: keep `.declaration` results.
    ///   - maxConcurrentFiles: files resolved at once.
    public static func search(
        _ id: JavaSymbolID,
        candidates: any JavaUsageCandidateSource,
        roots: [URL],
        environment: JavaReferenceEnvironment,
        includeDeclarations: Bool = true,
        maxConcurrentFiles: Int = 4
    ) -> AsyncStream<JavaUsage> {
        AsyncStream { continuation in
            let task = Task {
                await run(
                    id, candidates: candidates, roots: roots, environment: environment,
                    includeDeclarations: includeDeclarations, limit: max(1, maxConcurrentFiles)
                ) { usage in
                    continuation.yield(usage)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// All usages, sorted by file path then position.
    public static func collect(
        _ id: JavaSymbolID,
        candidates: any JavaUsageCandidateSource,
        roots: [URL],
        environment: JavaReferenceEnvironment,
        includeDeclarations: Bool = true,
        maxConcurrentFiles: Int = 4
    ) async -> [JavaUsage] {
        var all: [JavaUsage] = []
        for await usage in search(
            id, candidates: candidates, roots: roots, environment: environment,
            includeDeclarations: includeDeclarations, maxConcurrentFiles: maxConcurrentFiles
        ) {
            all.append(usage)
        }
        return all.sorted {
            if $0.url.path != $1.url.path { return $0.url.path < $1.url.path }
            return $0.byteRange.lowerBound < $1.byteRange.lowerBound
        }
    }

    /// The roots whose files can reference `id`: for a symbol declared in a project source set,
    /// the roots of every source set that sees that set; otherwise (JAR, JDK, no Gradle model)
    /// all of `roots`.
    public static func scopedRoots(
        for id: JavaSymbolID, roots: [URL], environment: JavaReferenceEnvironment
    ) async -> [URL] {
        guard let model = environment.gradleModel, let paths = environment.indexPaths,
              let declaringClass = id.declaringClass,
              let stub = await environment.index.classStub(qualifiedName: declaringClass),
              case .source(let declaringFile, _) = stub.origin,
              let home = model.sourceSet(containing: declaringFile) else { return roots }
        var visibleDirectories: [URL] = []
        for directory in home.sourceSet.sourceDirs {
            let shard = paths.projectSourcesShard(for: directory.standardizedFileURL).path
            for match in model.sourceSets(seeing: shard, paths: paths) {
                visibleDirectories.append(contentsOf: match.sourceSet.sourceDirs)
            }
        }
        visibleDirectories.append(contentsOf: home.sourceSet.sourceDirs)
        let prefixes = Set(visibleDirectories.map { directoryPrefix($0) })
        let kept = roots.filter { root in
            let path = directoryPrefix(root)
            return prefixes.contains { $0.hasPrefix(path) || path.hasPrefix($0) }
        }
        return kept.isEmpty ? roots : kept
    }

    // MARK: - Engine

    private static func run(
        _ id: JavaSymbolID,
        candidates: any JavaUsageCandidateSource,
        roots: [URL],
        environment: JavaReferenceEnvironment,
        includeDeclarations: Bool,
        limit: Int,
        emit: @escaping @Sendable (JavaUsage) -> Void
    ) async {
        let files: [URL]
        if case .local(let file, _) = id {
            files = [file]
        } else {
            let scoped = await scopedRoots(for: id, roots: roots, environment: environment)
            files = await candidates.candidateFiles(containing: id.simpleName, in: scoped)
        }
        if Task.isCancelled { return }

        await withTaskGroup(of: [JavaUsage].self) { group in
            var iterator = files.makeIterator()
            var running = 0
            func addNext() -> Bool {
                guard let file = iterator.next() else { return false }
                group.addTask {
                    if Task.isCancelled { return [] }
                    guard let text = await readText(of: file, environment: environment) else { return [] }
                    return await JavaFileUsageResolver.usages(of: id, source: text, url: file, environment: environment)
                }
                return true
            }
            while running < limit, addNext() { running += 1 }
            while let batch = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                for usage in batch where includeDeclarations || usage.kind != .declaration { emit(usage) }
                if addNext() {} else { running -= 1 }
            }
        }
    }

    private static func readText(of file: URL, environment: JavaReferenceEnvironment) async -> String? {
        if let reader = environment.openBuffer, let text = await reader(file) { return text }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    private static func directoryPrefix(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasSuffix("/") ? path : path + "/"
    }
}
