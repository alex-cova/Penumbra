import Foundation

/// A source of Java class stubs to index: a JDK (`ct.sym` or `jmods`), a dependency JAR, or a
/// project's source tree. The equivalent of `IndexableFilesIterator` in the handoff doc, except it
/// hands back already-decoded ``JavaClassStub``s rather than raw files -- binary roots (JDK, JARs)
/// only ever produce stubs via `ClassFileReader`, so there's no separate "file iteration" step
/// worth modeling independently for them.
public protocol JavaIndexableRoot: Sendable {
    /// A stable key used for shard file naming and cache invalidation (see ``JavaIndexStore``).
    var id: String { get }
    /// Detects whether this root has changed since it was last indexed.
    var stamp: JavaStamp { get }
    /// Reads and decodes every class this root exposes. May be slow (JDK ct.sym has thousands of
    /// classes); callers run this off the calling actor via ``JavaIndexScheduler``.
    func readStubs() throws -> [JavaClassStub]
}

/// Maps a JDK feature version to the single-character (or, pre-9, "8") release letter ct.sym uses
/// to group each API-surface directory, e.g. 17 -> "H", 24 -> "O". A ct.sym top-level directory
/// name is the set of letters for every release that shares an identical signature for the entries
/// underneath it (e.g. "MNO" covers 22, 23 and 24 unchanged), so a given feature version's data
/// lives under whichever directory *contains* its letter.
enum CtSymRelease {
    static func letter(forFeatureVersion version: Int) -> Character? {
        guard version >= 8 else { return nil }
        if version == 8 { return "8" }
        if version == 9 { return "9" }
        let offset = version - 10
        guard offset >= 0, offset < 26 else { return nil }
        let scalarValue = UInt8(ascii: "A") + UInt8(offset)
        return Character(UnicodeScalar(scalarValue))
    }
}

/// Reads a JDK's `lib/ct.sym`: a ZIP of `.sig` files that are themselves class files (public API
/// surface only), organized as `<releaseLetters>/<module>/<binary/path>.sig`. Picking the entry for
/// one feature version means finding the top-level directory whose letter set contains that
/// version's letter.
public struct JDKCtSymRoot: JavaIndexableRoot {
    private let installation: JDKInstallation
    public let id: String

    public init(installation: JDKInstallation) {
        self.installation = installation
        self.id = "jdk-ctsym-\(installation.cacheKey)"
    }

    public var stamp: JavaStamp {
        JavaStamp(url: installation.ctSym) ?? JavaStamp(size: 0, modificationDate: 0)
    }

    public func readStubs() throws -> [JavaClassStub] {
        guard let releaseLetter = CtSymRelease.letter(forFeatureVersion: installation.featureVersion) else {
            return []
        }
        let archive = try ZipArchive(url: installation.ctSym)
        var stubs: [JavaClassStub] = []
        stubs.reserveCapacity(archive.entries.count)
        for entry in archive.entries {
            guard entry.name.hasSuffix(".sig") else { continue }
            let components = entry.name.split(separator: "/", maxSplits: 1)
            guard components.count == 2, components[0].contains(releaseLetter) else { continue }
            let rest = components[1]
            guard let moduleSeparator = rest.firstIndex(of: "/") else { continue }
            let module = String(rest[rest.startIndex..<moduleSeparator])
            let path = String(rest[rest.index(after: moduleSeparator)...])
            let simpleName = (path as NSString).deletingPathExtension
            // module-info/package-info carry no completable API surface.
            if simpleName.hasSuffix("module-info") || simpleName.hasSuffix("package-info") { continue }
            guard let data = try? archive.data(for: entry) else { continue }
            guard let stub = try? ClassFileReader.read(data, origin: .jdkModule(module)) else { continue }
            stubs.append(stub)
        }
        return stubs
    }
}

/// Reads a JDK's `jmods/` directory: one `.jmod` per module, each a ZIP-format archive whose class
/// files live under a `classes/` prefix. Used only when `ct.sym` is absent (some distributions omit
/// it) or when a caller specifically wants module structure `ct.sym` doesn't preserve.
public struct JModsRoot: JavaIndexableRoot {
    private let installation: JDKInstallation
    public let id: String

    public init(installation: JDKInstallation) {
        self.installation = installation
        self.id = "jdk-jmods-\(installation.cacheKey)"
    }

    public var stamp: JavaStamp {
        JavaStamp(url: installation.jmodsDir) ?? JavaStamp(size: 0, modificationDate: 0)
    }

    public func readStubs() throws -> [JavaClassStub] {
        guard let jmodFiles = try? FileManager.default.contentsOfDirectory(at: installation.jmodsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        var stubs: [JavaClassStub] = []
        for jmodURL in jmodFiles where jmodURL.pathExtension == "jmod" {
            let moduleName = jmodURL.deletingPathExtension().lastPathComponent
            guard let archive = try? ZipArchive(url: jmodURL) else { continue }
            for entry in archive.entries {
                guard entry.name.hasPrefix("classes/"), entry.name.hasSuffix(".class") else { continue }
                let path = String(entry.name.dropFirst("classes/".count))
                if path == "module-info.class" || path.hasSuffix("/package-info.class") { continue }
                guard let data = try? archive.data(for: entry) else { continue }
                guard let stub = try? ClassFileReader.read(data, origin: .jdkModule(moduleName)) else { continue }
                stubs.append(stub)
            }
        }
        return stubs
    }
}

/// Reads a single dependency JAR (from Gradle/Maven caches or a loose `lib/*.jar`) into stubs.
/// Handles multi-release JARs (`META-INF/versions/N/...`) by preferring the highest `N` at or
/// below the project's language level over the base entry.
public struct JarRoot: JavaIndexableRoot {
    private let jarURL: URL
    private let languageLevel: Int
    public let id: String

    public init(jarURL: URL, languageLevel: Int = Int.max) {
        self.jarURL = jarURL
        self.languageLevel = languageLevel
        self.id = "jar-\(jarURL.path)"
    }

    public var stamp: JavaStamp {
        JavaStamp(url: jarURL) ?? JavaStamp(size: 0, modificationDate: 0)
    }

    public func readStubs() throws -> [JavaClassStub] {
        let archive = try ZipArchive(url: jarURL)
        // binaryPath (e.g. "com/example/Foo.class") -> best entry, keeping the highest
        // multi-release version at or below `languageLevel`, or the base (un-versioned) entry.
        var bestByPath: [String: (entry: ZipEntry, version: Int)] = [:]
        for entry in archive.entries {
            guard entry.name.hasSuffix(".class") else { continue }
            let simpleName = (entry.name as NSString).lastPathComponent
            if simpleName == "module-info.class" || simpleName == "package-info.class" { continue }

            var binaryPath = entry.name
            var version = 0
            if entry.name.hasPrefix("META-INF/versions/") {
                let rest = entry.name.dropFirst("META-INF/versions/".count)
                guard let slash = rest.firstIndex(of: "/"), let n = Int(rest[rest.startIndex..<slash]) else { continue }
                guard n <= languageLevel else { continue }
                version = n
                binaryPath = String(rest[rest.index(after: slash)...])
            }
            if let existing = bestByPath[binaryPath], existing.version >= version { continue }
            bestByPath[binaryPath] = (entry, version)
        }

        var stubs: [JavaClassStub] = []
        stubs.reserveCapacity(bestByPath.count)
        for (_, best) in bestByPath {
            guard let data = try? archive.data(for: best.entry) else { continue }
            guard let stub = try? ClassFileReader.read(data, origin: .jar(jarURL)) else { continue }
            stubs.append(stub)
        }
        return stubs
    }
}
