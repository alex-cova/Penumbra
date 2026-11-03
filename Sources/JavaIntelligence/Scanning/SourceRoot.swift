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
    /// True for annotation-processor output (`build/generated/...`). Its files are indexed like any
    /// others but must never be edited, so refactorings (rename) refuse to touch them.
    public let isGenerated: Bool

    /// Directory names never worth descending into: VCS metadata, build output, and dependency
    /// caches that may themselves contain (irrelevant, possibly huge numbers of) `.java` files.
    public static let ignoredDirectoryNames: Set<String> = [
        ".git", "build", ".gradle", "out", "node_modules", ".idea", "target", ".swiftpm", "bin"
    ]

    public init(directory: URL, isGenerated: Bool = false) {
        self.directory = directory
        self.isGenerated = isGenerated
        self.id = "source-\(directory.path)"
    }

    public var stamp: JavaStamp {
        // A regular root is kept fresh by the project watcher: a `.java` change under it makes
        // `IDEJavaSupport.filesDidChange` re-index it with `force`, so for the scheduler's own
        // coarse check the directory's mtime is enough (it moves when an entry is added, removed or
        // renamed). That does not hold for annotation-processor output: a processor rewrites
        // `build/generated/.../p/Foo_Impl.java` in place, which never touches the root's mtime, and
        // those directories are not name-index roots, so the watcher's per-root path does not apply
        // to them. A generated root is therefore stamped by what is in it.
        if isGenerated { return contentStamp }
        // `JavaStamp(url:)` isn't reusable here: `.fileSizeKey` resolves to `nil` for directories
        // on APFS, so that initializer always fails for a directory URL.
        let modificationDate = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        return JavaStamp(size: 0, modificationDate: modificationDate)
    }

    /// Size: how many `.java` files and how many bytes they hold. Date: the newest modification
    /// time among them and the directories above them. Any file added, removed, rewritten or
    /// renamed under the root moves at least one of the three. A stat per entry, no reads, so
    /// checking an unchanged root stays far cheaper than parsing it.
    var contentStamp: JavaStamp {
        var count: Int64 = 0
        var bytes: Int64 = 0
        var newest: TimeInterval = 0
        func note(_ url: URL, _ values: URLResourceValues?) {
            if let date = values?.contentModificationDate?.timeIntervalSince1970 { newest = max(newest, date) }
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        note(directory, try? directory.resourceValues(forKeys: Set(keys)))
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return JavaStamp(size: 0, modificationDate: newest) }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if Self.ignoredDirectoryNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                } else {
                    note(url, values)
                }
                continue
            }
            guard url.pathExtension == "java" else { continue }
            count += 1
            bytes += Int64(values?.fileSize ?? 0)
            note(url, values)
        }
        // Count and bytes share the size field: either alone can stay equal across an edit.
        return JavaStamp(size: count << 40 ^ bytes, modificationDate: newest)
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

    /// Every `.java` file under `directory`, without parsing them.
    public func javaFileURLs() -> [URL] {
        enumerateJavaFiles() ?? []
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
