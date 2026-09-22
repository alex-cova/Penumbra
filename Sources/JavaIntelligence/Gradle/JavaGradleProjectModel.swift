import Foundation

/// The decoded output of ``GradleProjectModelScript``. Gradle resolves each source set's compile
/// classpath; Umbra keeps that split so completion in a file sees only the source set that contains
/// it (its own sources, the source sets it depends on, and the external jars on that classpath).
///
/// All `URL`s are absolute `file://` URLs (the script emits `file.toURI().toString()` so `Codable`'s
/// single-string `URL` decoding produces a proper file URL rather than a scheme-less one).
public struct JavaGradleProjectModel: Codable, Sendable {
    public struct ProjectDependency: Codable, Hashable, Sendable {
        public let projectPath: String
        /// Source set of the dependency project that this edge compiles against. `main` for a normal
        /// `project(":lib")`; `testFixtures` when the resolved variant is a test-fixtures variant.
        public let sourceSetName: String

        public init(projectPath: String, sourceSetName: String) {
            self.projectPath = projectPath
            self.sourceSetName = sourceSetName
        }
    }

    public struct SourceSet: Codable, Sendable {
        public let name: String
        public let sourceDirs: [URL]
        /// Jars on this source set's compile classpath (`compileClasspath`, `testCompileClasspath`,
        /// `integrationTestCompileClasspath`, …). Does not include project dependencies or
        /// `runtimeOnly` artifacts.
        public let compileClasspathJars: [URL]
        public let projectDependencies: [ProjectDependency]

        public init(
            name: String,
            sourceDirs: [URL] = [],
            compileClasspathJars: [URL] = [],
            projectDependencies: [ProjectDependency] = []
        ) {
            self.name = name
            self.sourceDirs = sourceDirs
            self.compileClasspathJars = compileClasspathJars
            self.projectDependencies = projectDependencies
        }
    }

    public struct Subproject: Codable, Sendable {
        /// Gradle project path, e.g. `:`, `:app`, `:lib:core`.
        public let path: String
        public let directory: URL
        /// `nil` for a project with no Java plugin applied (a pure aggregator) or where neither a
        /// toolchain nor `sourceCompatibility` could be read.
        public let languageLevel: Int?
        public let sourceSets: [SourceSet]

        public init(
            path: String,
            directory: URL,
            languageLevel: Int? = nil,
            sourceSets: [SourceSet] = []
        ) {
            self.path = path
            self.directory = directory
            self.languageLevel = languageLevel
            self.sourceSets = sourceSets
        }

        /// Convenience for tests that still think in main/test directories and jars. Builds a `main`
        /// source set and, when any test input is present, a `test` source set that depends on `main`.
        public init(
            path: String,
            directory: URL,
            sourceDirs: [URL] = [],
            testSourceDirs: [URL] = [],
            languageLevel: Int? = nil,
            compileClasspathJars: [URL] = [],
            testClasspathJars: [URL] = []
        ) {
            var sets: [SourceSet] = []
            if !sourceDirs.isEmpty || !compileClasspathJars.isEmpty {
                sets.append(SourceSet(name: "main", sourceDirs: sourceDirs, compileClasspathJars: compileClasspathJars))
            }
            if !testSourceDirs.isEmpty || !testClasspathJars.isEmpty {
                sets.append(SourceSet(
                    name: "test",
                    sourceDirs: testSourceDirs,
                    compileClasspathJars: testClasspathJars,
                    projectDependencies: [ProjectDependency(projectPath: path, sourceSetName: "main")]
                ))
            }
            self.init(path: path, directory: directory, languageLevel: languageLevel, sourceSets: sets)
        }

        /// Directories of the `main` source set. Kept so callers that only need production sources
        /// don't have to walk `sourceSets` themselves.
        public var sourceDirs: [URL] {
            sourceSets.first { $0.name == "main" }?.sourceDirs ?? []
        }

        public var testSourceDirs: [URL] {
            sourceSets.first { $0.name == "test" }?.sourceDirs ?? []
        }

        public var compileClasspathJars: [URL] {
            sourceSets.first { $0.name == "main" }?.compileClasspathJars ?? []
        }

        public var testClasspathJars: [URL] {
            sourceSets.first { $0.name == "test" }?.compileClasspathJars ?? []
        }
    }

    public let formatVersion: Int
    public let gradleVersion: String
    public let subprojects: [Subproject]
    /// Human-readable descriptions of dependencies that failed to resolve, collected across every
    /// subproject and source set. `lenient(true)` resolution means one bad dependency degrades
    /// gracefully instead of failing the whole sync.
    public let unresolved: [String]

    public init(formatVersion: Int, gradleVersion: String, subprojects: [Subproject], unresolved: [String] = []) {
        self.formatVersion = formatVersion
        self.gradleVersion = gradleVersion
        self.subprojects = subprojects
        self.unresolved = unresolved
    }
}

extension JavaGradleProjectModel {
    /// The source set whose directory is the longest prefix of `file`, or `nil` when the file is
    /// outside every source set (unsaved buffers, scripts at the project root).
    public func sourceSet(containing file: URL) -> (subproject: Subproject, sourceSet: SourceSet)? {
        let path = file.standardizedFileURL.path
        var bestLength = -1
        var best: (Subproject, SourceSet)?
        for subproject in subprojects {
            for sourceSet in subproject.sourceSets {
                for directory in sourceSet.sourceDirs {
                    let dirPath = Self.directoryPath(directory)
                    guard path == dirPath || path.hasPrefix(dirPath + "/") else { continue }
                    guard dirPath.count > bestLength else { continue }
                    bestLength = dirPath.count
                    best = (subproject, sourceSet)
                }
            }
        }
        return best
    }

    /// Shard paths a completion in `file` may see: this source set's directories and compile jars,
    /// plus the directories of each project dependency's source set (`main` if the named set is
    /// missing). `nil` when `file` is not in any source set, which means "do not scope".
    ///
    /// Paths match ``sourceIndexTargets(paths:)`` / ``jarIndexTargets(paths:)`` so they line up with
    /// the `shardPath` stored on each ``JavaIndex/Source``.
    public func visibleShardPaths(forFile file: URL, paths: JavaIndexPaths) -> Set<String>? {
        guard let match = sourceSet(containing: file) else { return nil }
        var shards = Set<String>()
        addSourceDirShards(match.sourceSet.sourceDirs, to: &shards, paths: paths)
        for jar in match.sourceSet.compileClasspathJars {
            shards.insert(paths.jarShard(jar).path)
        }
        for dependency in match.sourceSet.projectDependencies {
            guard let target = subprojects.first(where: { $0.path == dependency.projectPath }) else { continue }
            let set = target.sourceSets.first { $0.name == dependency.sourceSetName }
                ?? target.sourceSets.first { $0.name == "main" }
            if let set {
                addSourceDirShards(set.sourceDirs, to: &shards, paths: paths)
            }
        }
        return shards
    }

    /// Every source set's directories that actually exist on disk, deduplicated, with any directory
    /// nested inside another one already kept dropped -- overlapping `SourceRoot`s would otherwise
    /// walk (and index) the same `.java` files twice.
    public var existingSourceDirectories: [URL] {
        var all: [URL] = []
        var seen = Set<URL>()
        for subproject in subprojects {
            for sourceSet in subproject.sourceSets {
                for directory in sourceSet.sourceDirs {
                    let standardized = directory.standardizedFileURL
                    guard FileManager.default.fileExists(atPath: standardized.path) else { continue }
                    guard seen.insert(standardized).inserted else { continue }
                    all.append(standardized)
                }
            }
        }
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

    /// Every resolved jar across every source set, deduplicated -- shared dependencies between
    /// modules shouldn't be indexed twice. Visibility is a query-time concern, not an indexing one.
    public var classpathJars: [URL] {
        var set = Set<URL>()
        for subproject in subprojects {
            for sourceSet in subproject.sourceSets {
                set.formUnion(sourceSet.compileClasspathJars)
            }
        }
        return set.sorted { $0.path < $1.path }
    }

    /// The highest declared language level across every subproject, used to pick a JDK
    /// (`JDKLocator.select(minimumFeatureVersion:)`) and to let jar roots favor the newest
    /// applicable entry in a multi-release jar.
    public var maxLanguageLevel: Int? {
        subprojects.compactMap(\.languageLevel).max()
    }

    /// One ``SourceRoot`` per existing source directory, paired with the shard URL
    /// ``JavaIndexScheduler`` should write it to.
    public func sourceIndexTargets(paths: JavaIndexPaths) -> [(root: any JavaIndexableRoot, shardURL: URL)] {
        existingSourceDirectories.map { directory in
            (SourceRoot(directory: directory), paths.projectSourcesShard(for: directory))
        }
    }

    /// One ``JarRoot`` per unique resolved jar, paired with its shard URL.
    public func jarIndexTargets(paths: JavaIndexPaths) -> [(root: any JavaIndexableRoot, shardURL: URL)] {
        classpathJars.map { jarURL in
            (JarRoot(jarURL: jarURL, languageLevel: maxLanguageLevel ?? Int.max), paths.jarShard(jarURL))
        }
    }

    private func addSourceDirShards(_ directories: [URL], to shards: inout Set<String>, paths: JavaIndexPaths) {
        for directory in directories {
            let standardized = directory.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path) else { continue }
            shards.insert(paths.projectSourcesShard(for: standardized).path)
        }
    }

    private static func directoryPath(_ directory: URL) -> String {
        let path = directory.standardizedFileURL.path
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
