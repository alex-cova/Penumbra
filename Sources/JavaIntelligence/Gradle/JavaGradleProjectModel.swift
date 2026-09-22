import Foundation

/// The decoded output of ``GradleProjectModelScript``: what Gradle itself knows about a project
/// that a flat directory walk can't see -- module boundaries, per-module source sets, and resolved
/// dependencies. All `URL`s are absolute `file://` URLs (the script emits `file.toURI().toString()`
/// specifically so `Codable`'s single-string `URL` decoding produces a proper file URL rather than
/// a scheme-less one).
public struct JavaGradleProjectModel: Codable, Sendable {
    public struct Subproject: Codable, Sendable {
        /// Gradle project path, e.g. `:`, `:app`, `:lib:core`.
        public let path: String
        public let directory: URL
        public let sourceDirs: [URL]
        public let testSourceDirs: [URL]
        /// `nil` for a project with no Java plugin applied (a pure aggregator) or where neither a
        /// toolchain nor `sourceCompatibility` could be read.
        public let languageLevel: Int?
        public let compileClasspathJars: [URL]
        public let testClasspathJars: [URL]

        public init(
            path: String,
            directory: URL,
            sourceDirs: [URL] = [],
            testSourceDirs: [URL] = [],
            languageLevel: Int? = nil,
            compileClasspathJars: [URL] = [],
            testClasspathJars: [URL] = []
        ) {
            self.path = path
            self.directory = directory
            self.sourceDirs = sourceDirs
            self.testSourceDirs = testSourceDirs
            self.languageLevel = languageLevel
            self.compileClasspathJars = compileClasspathJars
            self.testClasspathJars = testClasspathJars
        }
    }

    public let formatVersion: Int
    public let gradleVersion: String
    public let subprojects: [Subproject]
    /// Human-readable descriptions of dependencies that failed to resolve, collected across every
    /// subproject/configuration -- `lenient(true)` resolution in the init script means one bad
    /// dependency degrades gracefully instead of failing the whole sync. Surfaced in Umbra's status
    /// bar / Gradle output panel rather than silently dropped.
    public let unresolved: [String]

    public init(formatVersion: Int, gradleVersion: String, subprojects: [Subproject], unresolved: [String] = []) {
        self.formatVersion = formatVersion
        self.gradleVersion = gradleVersion
        self.subprojects = subprojects
        self.unresolved = unresolved
    }
}

extension JavaGradleProjectModel {
    /// Every subproject's main+test source directories that actually exist on disk, deduplicated,
    /// with any directory nested inside another one already kept dropped -- overlapping
    /// `SourceRoot`s would otherwise walk (and index) the same `.java` files twice.
    public var existingSourceDirectories: [URL] {
        var all: [URL] = []
        var seen = Set<URL>()
        for subproject in subprojects {
            for directory in subproject.sourceDirs + subproject.testSourceDirs {
                let standardized = directory.standardizedFileURL
                guard FileManager.default.fileExists(atPath: standardized.path) else { continue }
                guard seen.insert(standardized).inserted else { continue }
                all.append(standardized)
            }
        }
        // Shortest paths first, so a parent directory is always considered (and kept) before any
        // of its descendants.
        let byLength = all.sorted { $0.path.count < $1.path.count }
        var kept: [URL] = []
        for candidate in byLength {
            let candidatePrefix = candidate.path.hasSuffix("/") ? candidate.path : candidate.path + "/"
            let isNested = kept.contains { existing in
                let existingPrefix = existing.path.hasSuffix("/") ? existing.path : existing.path + "/"
                return candidatePrefix.hasPrefix(existingPrefix)
            }
            guard !isNested else { continue }
            kept.append(candidate)
        }
        return kept
    }

    /// Every resolved jar across every subproject's compile + test classpaths, deduplicated --
    /// shared dependencies between modules shouldn't be indexed twice.
    public var classpathJars: [URL] {
        var set = Set<URL>()
        for subproject in subprojects {
            set.formUnion(subproject.compileClasspathJars)
            set.formUnion(subproject.testClasspathJars)
        }
        return set.sorted { $0.path < $1.path }
    }

    /// The highest declared language level across every subproject, used to pick a JDK
    /// (`JDKLocator.select(minimumFeatureVersion:)`) and to let ``classpathJarRoots(paths:)`` favor
    /// the newest applicable entry in a multi-release jar.
    public var maxLanguageLevel: Int? {
        subprojects.compactMap(\.languageLevel).max()
    }

    /// One ``SourceRoot`` per existing source directory, paired with the shard URL
    /// ``JavaIndexScheduler`` should write it to -- ready to hand to
    /// `JavaIndexScheduler.index(_:)` directly.
    public func sourceIndexTargets(paths: JavaIndexPaths) -> [(root: any JavaIndexableRoot, shardURL: URL)] {
        existingSourceDirectories.map { directory in
            (SourceRoot(directory: directory), paths.projectSourcesShard(for: directory))
        }
    }

    /// One ``JarRoot`` per unique resolved jar, paired with its shard URL -- ready to hand to
    /// `JavaIndexScheduler.index(_:)` directly.
    public func jarIndexTargets(paths: JavaIndexPaths) -> [(root: any JavaIndexableRoot, shardURL: URL)] {
        classpathJars.map { jarURL in
            (JarRoot(jarURL: jarURL, languageLevel: maxLanguageLevel ?? Int.max), paths.jarShard(jarURL))
        }
    }
}
