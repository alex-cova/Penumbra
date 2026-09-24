import Foundation

/// Describes what changed between two Gradle project models for incremental re-indexing.
public struct JavaGradleModelDiff: Sendable, Equatable {
    public let addedSourceDirectories: [URL]
    public let removedSourceDirectories: [URL]
    public let changedSourceDirectories: [URL]
    public let addedJars: [URL]
    public let removedJars: [URL]
    public let structuralChange: Bool

    public init(
        addedSourceDirectories: [URL],
        removedSourceDirectories: [URL],
        changedSourceDirectories: [URL],
        addedJars: [URL],
        removedJars: [URL],
        structuralChange: Bool
    ) {
        self.addedSourceDirectories = addedSourceDirectories
        self.removedSourceDirectories = removedSourceDirectories
        self.changedSourceDirectories = changedSourceDirectories
        self.addedJars = addedJars
        self.removedJars = removedJars
        self.structuralChange = structuralChange
    }

    public var isEmpty: Bool {
        addedSourceDirectories.isEmpty
            && removedSourceDirectories.isEmpty
            && changedSourceDirectories.isEmpty
            && addedJars.isEmpty
            && removedJars.isEmpty
    }

    /// When more than half of all index roots would change, a full rebuild is cheaper.
    public func shouldForceFullRebuild(totalSourceRoots: Int, totalJars: Int) -> Bool {
        if structuralChange { return true }
        let total = max(1, totalSourceRoots + totalJars)
        let changed = addedSourceDirectories.count + removedSourceDirectories.count
            + changedSourceDirectories.count + addedJars.count + removedJars.count
        return Double(changed) / Double(total) > 0.5
    }
}

extension JavaGradleProjectModel {
    public static func diff(old: JavaGradleProjectModel?, new: JavaGradleProjectModel) -> JavaGradleModelDiff {
        guard let old else {
            return JavaGradleModelDiff(
                addedSourceDirectories: new.existingSourceDirectories + new.existingGeneratedSourceDirectories,
                removedSourceDirectories: [],
                changedSourceDirectories: [],
                addedJars: new.classpathJars,
                removedJars: [],
                structuralChange: true
            )
        }

        let oldProjects = Set(old.subprojects.map(\.path))
        let newProjects = Set(new.subprojects.map(\.path))
        let structural = old.formatVersion != new.formatVersion || oldProjects != newProjects

        let oldSources = Set((old.existingSourceDirectories + old.existingGeneratedSourceDirectories).map(\.standardizedFileURL.path))
        let newSources = Set((new.existingSourceDirectories + new.existingGeneratedSourceDirectories).map(\.standardizedFileURL.path))
        let addedSources = newSources.subtracting(oldSources).sorted().map { URL(fileURLWithPath: $0) }
        let removedSources = oldSources.subtracting(newSources).sorted().map { URL(fileURLWithPath: $0) }

        let oldFingerprints = sourceSetFingerprints(old)
        let newFingerprints = sourceSetFingerprints(new)
        var changedSources: [URL] = []
        for (path, fingerprint) in newFingerprints where oldFingerprints[path] != nil && oldFingerprints[path] != fingerprint {
            if let url = new.existingSourceDirectories.first(where: { $0.standardizedFileURL.path == path })
                ?? new.existingGeneratedSourceDirectories.first(where: { $0.standardizedFileURL.path == path }) {
                changedSources.append(url)
            }
        }

        let oldJars = Set(old.classpathJars.map(\.standardizedFileURL.path))
        let newJars = Set(new.classpathJars.map(\.standardizedFileURL.path))
        let addedJars = newJars.subtracting(oldJars).sorted().map { URL(fileURLWithPath: $0) }
        let removedJars = oldJars.subtracting(newJars).sorted().map { URL(fileURLWithPath: $0) }

        return JavaGradleModelDiff(
            addedSourceDirectories: addedSources,
            removedSourceDirectories: removedSources,
            changedSourceDirectories: changedSources,
            addedJars: addedJars,
            removedJars: removedJars,
            structuralChange: structural
        )
    }

    private static func sourceSetFingerprints(_ model: JavaGradleProjectModel) -> [String: String] {
        var result: [String: String] = [:]
        for subproject in model.subprojects {
            for sourceSet in subproject.sourceSets {
                let key = fingerprint(sourceSet: sourceSet, projectPath: subproject.path)
                for directory in sourceSet.sourceDirs + sourceSet.generatedSourceDirs {
                    result[directory.standardizedFileURL.path] = key
                }
            }
        }
        return result
    }

    private static func fingerprint(sourceSet: SourceSet, projectPath: String) -> String {
        let jars = sourceSet.compileClasspathJars.map(\.path).sorted().joined(separator: "|")
        let runtime = sourceSet.runtimeClasspathJars.map(\.path).sorted().joined(separator: "|")
        let outputs = sourceSet.outputDirs.map(\.path).sorted().joined(separator: "|")
        let deps = sourceSet.projectDependencies.map { "\($0.projectPath):\($0.sourceSetName)" }.sorted().joined(separator: "|")
        return "\(projectPath)#\(sourceSet.name)|\(jars)|\(runtime)|\(outputs)|\(deps)"
    }
}
