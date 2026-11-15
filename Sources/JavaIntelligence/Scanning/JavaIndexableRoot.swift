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

    /// Whether `archive` carries API signatures for the release. A JDK's `ct.sym` holds the older
    /// releases only: for its own (JDK 21's `L/` is just `system-modules`) javac reads the runtime
    /// image instead, so indexing it gives no classes.
    static func hasSignatures(in archive: ZipArchive, forFeatureVersion version: Int) -> Bool {
        guard let letter = letter(forFeatureVersion: version) else { return false }
        return archive.entries.contains { entry in
            guard entry.name.hasSuffix(".sig") else { return false }
            let top = entry.name.prefix { $0 != "/" }
            return top.count < entry.name.count && top.contains(letter)
        }
    }

    /// The feature versions `archive` carries API signatures for (letters with at least one
    /// `.sig` below them). JDK 21's holds 8...20; JDK 22 and later also hold their own release.
    static func releasesWithSignatures(in archive: ZipArchive) -> Set<Int> {
        var letters = Set<Character>()
        var seenTops = Set<Substring>()
        for entry in archive.entries where entry.name.hasSuffix(".sig") {
            let top = entry.name.prefix { $0 != "/" }
            guard top.count < entry.name.count, seenTops.insert(top).inserted else { continue }
            letters.formUnion(top)
        }
        return Set((8...35).filter { version in letter(forFeatureVersion: version).map(letters.contains) ?? false })
    }
}

/// The platform roots a JDK can index: its own platform (``JDKIndexRoot``) and, from `ct.sym`,
/// the API of each older release `--release` accepts.
public enum JDKPlatformRoot {
    /// The releases `installation`'s `ct.sym` holds signatures for. Opens `ct.sym`'s central
    /// directory, so callers run it off the main actor. Empty without a `ct.sym`.
    public static func supportedReleases(of installation: JDKInstallation) -> Set<Int> {
        guard let archive = try? ZipArchive(url: installation.ctSym) else { return [] }
        return CtSymRelease.releasesWithSignatures(in: archive)
    }

    /// The root that indexes release `release`'s API as javac's `--release` sees it, with its
    /// shard kind, or `nil` when `ct.sym` has no signatures for it (JDK 8 has no `ct.sym`;
    /// releases below 8 are gone). The JDK's own release is ``JDKIndexRoot/make(for:)``.
    public static func make(for installation: JDKInstallation, release: Int) -> (root: any JavaIndexableRoot, kind: String)? {
        guard release != installation.featureVersion else { return JDKIndexRoot.make(for: installation) }
        guard supportedReleases(of: installation).contains(release) else { return nil }
        return (JDKCtSymRoot(installation: installation, release: release), "ctsym-release-\(release)")
    }
}

/// Picks what to index for a JDK: `ct.sym` when it has signatures for the JDK's own release, else
/// `jmods/` (the shard kind differs, so a shard written empty from `ct.sym` is never read again).
public enum JDKIndexRoot {
    public static func make(for installation: JDKInstallation) -> (root: any JavaIndexableRoot, kind: String) {
        let ctSym = JDKCtSymRoot(installation: installation)
        let hasSignatures = (try? ZipArchive(url: installation.ctSym)).map {
            CtSymRelease.hasSignatures(in: $0, forFeatureVersion: installation.featureVersion)
        } ?? false
        if hasSignatures || !installation.hasJmods { return (ctSym, "ctsym") }
        return (JModsRoot(installation: installation), "jmods-exported")
    }
}

/// Reads a JDK's `lib/ct.sym`: a ZIP of `.sig` files that are themselves class files (public API
/// surface only), organized as `<releaseLetters>/<module>/<binary/path>.sig`. Picking the entry for
/// one feature version means finding the top-level directory whose letter set contains that
/// version's letter.
public struct JDKCtSymRoot: JavaIndexableRoot {
    private let installation: JDKInstallation
    /// The release whose signatures are read: the JDK's own feature version unless asked for
    /// another (`--release N`).
    public let release: Int
    public let id: String

    public init(installation: JDKInstallation, release: Int? = nil) {
        self.installation = installation
        self.release = release ?? installation.featureVersion
        self.id = release.map { "jdk-ctsym-\(installation.cacheKey)-release-\($0)" } ?? "jdk-ctsym-\(installation.cacheKey)"
    }

    public var stamp: JavaStamp {
        JavaStamp(url: installation.ctSym) ?? JavaStamp(size: 0, modificationDate: 0)
    }

    public func readStubs() throws -> [JavaClassStub] {
        guard let releaseLetter = CtSymRelease.letter(forFeatureVersion: release) else {
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
/// files live under a `classes/` prefix. Used when `ct.sym` is absent (some distributions omit it) or
/// has no signatures for the JDK's own release (see ``JDKIndexRoot``).
public struct JModsRoot: JavaIndexableRoot {
    private let installation: JDKInstallation
    public let id: String

    public init(installation: JDKInstallation) {
        self.installation = installation
        // `-exported`: shards written before non-exported packages were left out are not reused.
        self.id = "jdk-jmods-exported-\(installation.cacheKey)"
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
            // Only the packages the module exports to everyone, as `ct.sym` and `javac` see them
            // (`jdk.internal.misc` is in `java.base` but no code outside the JDK may name it). A
            // module-info that cannot be read keeps every package, as before.
            let exports = archive.entries.first { $0.name == "classes/module-info.class" }
                .flatMap { try? archive.data(for: $0) }
                .flatMap { try? ClassFileReader.unqualifiedExports(ofModuleInfo: $0) }
            for entry in archive.entries {
                guard entry.name.hasPrefix("classes/"), entry.name.hasSuffix(".class") else { continue }
                let path = String(entry.name.dropFirst("classes/".count))
                if path == "module-info.class" || path.hasSuffix("/package-info.class") { continue }
                if let exports {
                    let package = (path as NSString).deletingLastPathComponent.replacingOccurrences(of: "/", with: ".")
                    guard exports.contains(package) else { continue }
                }
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
    public let jarURL: URL
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
