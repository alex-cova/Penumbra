import Foundation

/// A project's `.java` source tree: walks the directory for `.java` files and parses each with
/// ``JavaSourceStubBuilder``. Unlike the binary roots (JDK, JARs), source stubs keep private and
/// package-private members (same-file/same-package completion needs them) and every type
/// reference stays `.unresolved`/`.classType`-as-written rather than being checked against a
/// classpath.
///
/// `readStubs()` (the ``JavaIndexableRoot`` conformance) returns the flattened class list, for
/// indexing/completion. Callers that also need each file's package/import list (the semantics
/// layer resolving an `.unresolved` reference) call ``readSourceFiles()`` directly, since imports
/// are file-scoped and don't fit the class-only `JavaIndexableRoot` protocol.
public struct SourceRoot: JavaIndexableRoot {
    public let directory: URL
    public let id: String

    /// Directory names never worth descending into: VCS metadata, build output, and dependency
    /// caches that may themselves contain (irrelevant, possibly huge numbers of) `.java` files.
    public static let ignoredDirectoryNames: Set<String> = [
        ".git", "build", ".gradle", "out", "node_modules", ".idea", "target", ".swiftpm", "bin"
    ]

    public init(directory: URL) {
        self.directory = directory
        self.id = "source-\(directory.path)"
    }

    public var stamp: JavaStamp {
        // A directory's own mtime changes whenever an entry is added/removed/renamed, and
        // JavaIndexScheduler re-reads this root (all its files) whenever *any* file underneath it
        // changes anyway via the FSEvents watcher invalidating it -- see IDEJavaSupport (Umbra
        // wiring). For the root's own coarse staleness check, the directory's own mtime is enough.
        // `JavaStamp(url:)` isn't reusable here: `.fileSizeKey` resolves to `nil` for directories
        // on APFS, so that initializer always fails for a directory URL.
        let modificationDate = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        return JavaStamp(size: 0, modificationDate: modificationDate)
    }

    public func readStubs() throws -> [JavaClassStub] {
        readSourceFiles().flatMap(\.classes)
    }

    /// Every `.java` file under `directory`, each parsed into its full package/import/class detail.
    public func readSourceFiles() -> [JavaSourceFileStubs] {
        guard let urls = enumerateJavaFiles() else { return [] }
        var results: [JavaSourceFileStubs] = []
        results.reserveCapacity(urls.count)
        for url in urls {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            results.append(JavaSourceStubBuilder.build(source: source, url: url))
        }
        return results
    }

    private func enumerateJavaFiles() -> [URL]? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var results: [URL] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if Self.ignoredDirectoryNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if url.pathExtension == "java" {
                results.append(url)
            }
        }
        return results
    }
}
