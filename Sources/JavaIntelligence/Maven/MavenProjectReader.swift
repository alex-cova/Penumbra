import Foundation

/// Reads a Maven reactor from disk. No Maven process runs: parents, BOMs and dependencies come from
/// the local repository. Call ``read(root:options:store:)`` from any actor; the work happens off it.
public enum MavenProjectReader {
    public static func read(
        root: URL,
        options: MavenReadOptions = MavenReadOptions(),
        store: MavenPOMStore = .shared
    ) async throws -> MavenProjectModel {
        let root = root
        let options = options
        let store = store
        return try await Task.detached(priority: .userInitiated) {
            try build(root: root, options: options, store: store)
        }.value
    }

    /// Synchronous read for a caller that is already off the main actor.
    public static func build(
        root: URL,
        options: MavenReadOptions = MavenReadOptions(),
        store: MavenPOMStore = .shared
    ) throws -> MavenProjectModel {
        let projectRoot = root.standardizedFileURL
        let config = MavenConfigFile.read(projectRoot: projectRoot)
        let repository = MavenLocalRepository.resolve(
            projectRoot: projectRoot,
            mavenConfig: config,
            userHome: options.userHome,
            environment: options.environment
        )
        let effective = try MavenReactor.modules(
            projectRoot: projectRoot, repository: repository, options: options, config: config, store: store
        )
        let resolutions = MavenDependencyResolver.resolve(modules: effective, repository: repository, store: store)
        let modules = effective.map { module in
            published(module, resolution: resolutions[module.path])
        }
        var missing: [MavenDependency] = []
        var seenMissing = Set<String>()
        func addMissing(_ dependency: MavenDependency) {
            guard seenMissing.insert(dependency.mediationKey + ":" + dependency.version).inserted else { return }
            missing.append(dependency)
        }
        for module in effective {
            for dependency in module.missingPOMs { addMissing(dependency) }
        }
        for resolution in resolutions.values {
            for dependency in resolution.missing { addMissing(dependency) }
        }
        return MavenProjectModel(
            modules: modules,
            profiles: profileStates(effective),
            repositories: repositories(effective),
            missing: missing,
            unresolved: missing.map(\.coordinate).sorted()
        )
    }

    private static func published(_ module: MavenEffectiveModule, resolution: MavenResolution?) -> MavenModule {
        let resolution = resolution
        func edges(_ values: [MavenProjectEdge]?) -> [MavenModuleDependency] {
            (values ?? []).map { MavenModuleDependency(projectPath: $0.projectPath, sourceSetName: $0.sourceSetName) }
        }
        return MavenModule(
            path: module.path,
            directory: module.directory,
            groupId: module.gav.groupId,
            artifactId: module.gav.artifactId,
            version: module.gav.version,
            packaging: module.packaging,
            plugins: module.plugins,
            dependencyTree: (resolution?.tree ?? []).map(MavenProjectModel.node(from:)),
            sourceDirectories: module.sourceDirectories,
            testSourceDirectories: module.testSourceDirectories,
            outputDirectory: module.outputDirectory,
            testOutputDirectory: module.testOutputDirectory,
            generatedSourceDirectories: module.generatedSourceDirectories,
            languageLevel: module.languageLevel,
            compileClasspathJars: resolution?.compileJars ?? [],
            runtimeClasspathJars: resolution?.runtimeJars ?? [],
            testClasspathJars: resolution?.testJars ?? [],
            compileProjectDependencies: edges(resolution?.compileProjects),
            runtimeProjectDependencies: edges(resolution?.runtimeProjects),
            testProjectDependencies: edges(resolution?.testProjects),
            annotationProcessorJars: resolution?.processorJars ?? [],
            usesJacocoPrepareAgent: module.usesJacocoPrepareAgent,
            surefireArgLine: module.surefireArgLine
        )
    }

    private static func profileStates(_ modules: [MavenEffectiveModule]) -> [MavenProfileState] {
        var active: [String: Bool] = [:]
        var order: [String] = []
        for module in modules {
            for (id, isActive) in module.profiles where !id.isEmpty {
                if active[id] == nil { order.append(id) }
                active[id] = (active[id] ?? false) || isActive
            }
        }
        return order.map { MavenProfileState(id: $0, active: active[$0] ?? false) }
    }

    private static func repositories(_ modules: [MavenEffectiveModule]) -> [MavenRepository] {
        var result: [MavenRepository] = []
        var seen = Set<String>()
        for module in modules {
            for repository in module.repositories {
                let key = repository.id.isEmpty ? repository.url : repository.id
                guard seen.insert(key).inserted else { continue }
                result.append(repository)
            }
        }
        return result
    }
}

extension MavenDependency {
    /// `group:artifact:version`, plus type and classifier when they are not a plain jar.
    var coordinate: String {
        var text = "\(groupId):\(artifactId):\(version)"
        if resolvedType != "jar" || !resolvedClassifier.isEmpty {
            text += ":\(resolvedType)"
            if !resolvedClassifier.isEmpty { text += ":\(resolvedClassifier)" }
        }
        return text
    }
}
