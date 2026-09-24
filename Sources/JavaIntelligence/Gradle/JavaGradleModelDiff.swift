import Foundation

/// What changed between two synced ``JavaGradleProjectModel``s, so a re-sync can update only the
/// affected indexes and providers instead of rebuilding everything.
///
/// Source sets are keyed `subprojectPath:name` (for example `:app:test`).
public enum JavaGradleModelDiff {
    /// The change of one source set present in both models.
    public struct SourceSetChange: Equatable, Sendable {
        public let key: String
        public var addedCompileJars: [URL] = []
        public var removedCompileJars: [URL] = []
        public var addedRuntimeJars: [URL] = []
        public var removedRuntimeJars: [URL] = []
        public var addedSourceDirs: [URL] = []
        public var removedSourceDirs: [URL] = []
        public var addedGeneratedDirs: [URL] = []
        public var removedGeneratedDirs: [URL] = []
        /// Compile or runtime project dependencies differ.
        public var projectDependenciesChanged = false
        /// Any classpath input differs: compile/runtime jars, project dependencies, output dirs or
        /// annotation processor jars.
        public var classpathChanged = false
        public var sourceRootsChanged = false

        public init(key: String) { self.key = key }
    }

    public struct Result: Equatable, Sendable {
        public var addedSourceSets: [String] = []
        public var removedSourceSets: [String] = []
        public var changedSourceSets: [SourceSetChange] = []
        /// The highest language level, or any subproject's level, differs.
        public var languageLevelChanged = false
        /// Compile/runtime jars or project dependencies changed in any source set (including source
        /// sets that were added or removed).
        public var classpathChanged = false
        /// Any source or generated directory was added or removed.
        public var sourceRootsChanged = false
        /// The models differ in some other way (tasks, unresolved list, gradle version, ...).
        public var otherChanged = false
        /// The first apply (no previous model): everything is new.
        public var isInitial = false

        public init() {}

        /// Nothing changed at all.
        public var isEmpty: Bool {
            !isInitial && addedSourceSets.isEmpty && removedSourceSets.isEmpty && changedSourceSets.isEmpty
                && !languageLevelChanged && !classpathChanged && !sourceRootsChanged && !otherChanged
        }

        /// An apply must rebuild everything: nothing to compare with, or the language level moved
        /// (it selects the JDK and the multi-release view of every jar).
        public var requiresFullApply: Bool { isInitial || languageLevelChanged }
    }

    public static func diff(from old: JavaGradleProjectModel?, to new: JavaGradleProjectModel) -> Result {
        var result = Result()
        guard let old else {
            result.isInitial = true
            result.classpathChanged = true
            result.sourceRootsChanged = true
            result.addedSourceSets = sourceSets(in: new).keys.sorted()
            return result
        }
        let oldSets = sourceSets(in: old)
        let newSets = sourceSets(in: new)
        result.addedSourceSets = newSets.keys.filter { oldSets[$0] == nil }.sorted()
        result.removedSourceSets = oldSets.keys.filter { newSets[$0] == nil }.sorted()

        for key in newSets.keys.sorted() {
            guard let before = oldSets[key], let after = newSets[key], before != after else { continue }
            var change = SourceSetChange(key: key)
            (change.addedCompileJars, change.removedCompileJars) = delta(before.compileClasspathJars, after.compileClasspathJars)
            (change.addedRuntimeJars, change.removedRuntimeJars) = delta(before.runtimeClasspathJars, after.runtimeClasspathJars)
            (change.addedSourceDirs, change.removedSourceDirs) = delta(before.sourceDirs, after.sourceDirs)
            (change.addedGeneratedDirs, change.removedGeneratedDirs) = delta(before.generatedSourceDirs, after.generatedSourceDirs)
            change.projectDependenciesChanged = before.projectDependencies != after.projectDependencies
                || before.runtimeProjectDependencies != after.runtimeProjectDependencies
            change.classpathChanged = before.compileClasspathJars != after.compileClasspathJars
                || before.runtimeClasspathJars != after.runtimeClasspathJars
                || change.projectDependenciesChanged
                || before.outputDirs != after.outputDirs
                || before.annotationProcessorJars != after.annotationProcessorJars
            change.sourceRootsChanged = !change.addedSourceDirs.isEmpty || !change.removedSourceDirs.isEmpty
                || !change.addedGeneratedDirs.isEmpty || !change.removedGeneratedDirs.isEmpty
            result.changedSourceSets.append(change)
        }

        let oldLevels = Dictionary(old.subprojects.map { ($0.path, $0.languageLevel) }, uniquingKeysWith: { first, _ in first })
        let newLevels = Dictionary(new.subprojects.map { ($0.path, $0.languageLevel) }, uniquingKeysWith: { first, _ in first })
        result.languageLevelChanged = old.maxLanguageLevel != new.maxLanguageLevel
            || newLevels.contains { key, level in oldLevels[key].map { $0 != level } ?? false }

        let addedOrRemoved = result.addedSourceSets + result.removedSourceSets
        result.classpathChanged = result.changedSourceSets.contains { $0.classpathChanged }
            || addedOrRemoved.contains { key in
                guard let set = newSets[key] ?? oldSets[key] else { return false }
                return !set.compileClasspathJars.isEmpty || !set.runtimeClasspathJars.isEmpty
                    || !set.projectDependencies.isEmpty || !set.runtimeProjectDependencies.isEmpty
                    || !set.sourceDirs.isEmpty
            }
        result.sourceRootsChanged = result.changedSourceSets.contains { $0.sourceRootsChanged }
            || addedOrRemoved.contains { key in
                guard let set = newSets[key] ?? oldSets[key] else { return false }
                return !set.sourceDirs.isEmpty || !set.generatedSourceDirs.isEmpty
            }
        // Models differ but no source set or language level explains it: tasks, subprojects
        // without source sets, unresolved dependencies, and so on.
        result.otherChanged = old != new && result.addedSourceSets.isEmpty && result.removedSourceSets.isEmpty
            && result.changedSourceSets.isEmpty && !result.languageLevelChanged
        return result
    }

    // MARK: - Apply planning

    /// What an apply must do to the loaded indexes, from the shards and roots currently loaded and
    /// the new model's targets. Comparing against what is loaded (not against the old model) also
    /// picks up directories that appeared on disk since the last apply.
    public struct ApplyPlan: Sendable {
        public typealias Target = (root: any JavaIndexableRoot, shardURL: URL)

        public var sourceTargets: [Target]
        public var jarTargets: [Target]
        /// Targets whose shard is not loaded yet.
        public var addedSourceTargets: [Target]
        public var addedJarTargets: [Target]
        /// Loaded shard paths the new model no longer has.
        public var removedShardPaths: Set<String>
        public var nameRoots: [URL]
        public var addedNameRoots: [URL]
        public var removedNameRoots: [URL]
    }

    /// - Parameters:
    ///   - loadedShardPaths: shard paths of the loaded project-source and jar readers.
    ///   - loadedNameRoots: standardized paths of the roots the name index currently has.
    public static func plan(
        for model: JavaGradleProjectModel,
        paths: JavaIndexPaths,
        loadedShardPaths: Set<String>,
        loadedNameRoots: Set<String>
    ) -> ApplyPlan {
        let sources = model.sourceIndexTargets(paths: paths)
        let jars = model.jarIndexTargets(paths: paths)
        let wanted = Set((sources + jars).map(\.shardURL.path))
        let roots = model.existingSourceDirectories
        let rootPaths = Set(roots.map(\.path))
        return ApplyPlan(
            sourceTargets: sources,
            jarTargets: jars,
            addedSourceTargets: sources.filter { !loadedShardPaths.contains($0.shardURL.path) },
            addedJarTargets: jars.filter { !loadedShardPaths.contains($0.shardURL.path) },
            removedShardPaths: loadedShardPaths.subtracting(wanted),
            nameRoots: roots,
            addedNameRoots: roots.filter { !loadedNameRoots.contains($0.path) },
            removedNameRoots: loadedNameRoots.subtracting(rootPaths).sorted().map { URL(fileURLWithPath: $0) }
        )
    }

    // MARK: - Helpers

    private static func sourceSets(in model: JavaGradleProjectModel) -> [String: JavaGradleProjectModel.SourceSet] {
        var result: [String: JavaGradleProjectModel.SourceSet] = [:]
        for subproject in model.subprojects {
            for set in subproject.sourceSets {
                result["\(subproject.path):\(set.name)"] = set
            }
        }
        return result
    }

    private static func delta(_ old: [URL], _ new: [URL]) -> (added: [URL], removed: [URL]) {
        let oldSet = Set(old.map(\.standardizedFileURL))
        let newSet = Set(new.map(\.standardizedFileURL))
        return (
            new.filter { !oldSet.contains($0.standardizedFileURL) },
            old.filter { !newSet.contains($0.standardizedFileURL) }
        )
    }
}
