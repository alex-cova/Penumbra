import Foundation

/// One node of a module's dependency tree, before conflict losers are dropped from the classpath.
struct MavenResolvedNode: Sendable {
    var dependency: MavenDependency
    var scope: String
    var depth: Int
    var order: Int
    var omitted: Bool
    var missing: Bool
    var file: URL?
    var projectPath: String?
    var sourceSetName: String
    var children: [MavenResolvedNode]
}

/// Compile, runtime and test classpaths of one module, plus the tree the sidebar draws.
struct MavenResolution: Sendable {
    var compileJars: [URL]
    var runtimeJars: [URL]
    var testJars: [URL]
    var compileProjects: [MavenProjectEdge]
    var runtimeProjects: [MavenProjectEdge]
    var testProjects: [MavenProjectEdge]
    var processorJars: [URL]
    var tree: [MavenResolvedNode]
    var missing: [MavenDependency]
}

struct MavenProjectEdge: Hashable, Sendable {
    var projectPath: String
    var sourceSetName: String
}

/// Maven 3 dependency mediation for one reactor.
enum MavenDependencyResolver {
    static func resolve(
        modules: [MavenEffectiveModule],
        repository: URL,
        store: MavenPOMStore
    ) -> [String: MavenResolution] {
        let reactor = Dictionary(modules.map { ($0.gav.groupId + ":" + $0.gav.artifactId, $0) }, uniquingKeysWith: { first, _ in first })
        var results: [String: MavenResolution] = [:]
        for module in modules {
            results[module.path] = resolve(module: module, reactor: reactor, repository: repository, store: store)
        }
        return results
    }

    private static func resolve(
        module: MavenEffectiveModule,
        reactor: [String: MavenEffectiveModule],
        repository: URL,
        store: MavenPOMStore
    ) -> MavenResolution {
        var order = 0
        let tree = walk(
            dependencies: module.dependencies, depth: 1, parentScope: nil, exclusions: [],
            management: module.dependencyManagement, reactor: reactor, repository: repository,
            store: store, order: &order, stack: []
        )
        let mediated = mediate(tree, management: module.dependencyManagement, repository: repository, reactor: reactor)
        return classpaths(mediated, module: module, repository: repository, reactor: reactor)
    }

    private static func walk(
        dependencies: [MavenDependency],
        depth: Int,
        parentScope: String?,
        exclusions: [MavenExclusion],
        management: [MavenDependency],
        reactor: [String: MavenEffectiveModule],
        repository: URL,
        store: MavenPOMStore,
        order: inout Int,
        stack: Set<String>
    ) -> [MavenResolvedNode] {
        var nodes: [MavenResolvedNode] = []
        for declared in dependencies {
            if exclusions.contains(where: { $0.matches(group: declared.groupId, artifact: declared.artifactId) }) {
                continue
            }
            let managed = applyManagement(declared, management: management, transitive: parentScope != nil)
            guard !managed.groupId.isEmpty, !managed.artifactId.isEmpty else { continue }
            let scope = effectiveScope(declared: managed.scope, parent: parentScope)
            guard let scope else { continue }
            if parentScope != nil && managed.optional { continue }
            let version = resolveVersion(managed, repository: repository, reactor: reactor)
            var dependency = managed
            dependency.version = version
            let identity = "\(dependency.groupId):\(dependency.artifactId):\(dependency.version)"
            order += 1
            var node = MavenResolvedNode(
                dependency: dependency, scope: scope, depth: depth, order: order, omitted: false,
                missing: false, file: nil, projectPath: nil, sourceSetName: "main", children: []
            )
            let reactorModule = reactorModule(for: dependency, reactor: reactor)
            if let reactorModule {
                node.projectPath = reactorModule.path
                node.sourceSetName = dependency.type == "test-jar" || dependency.resolvedClassifier == "tests" ? "test" : "main"
            } else if dependency.resolvedType != "pom" {
                node.file = artifactFile(dependency, repository: repository)
                node.missing = node.file == nil && dependency.scope != "system"
            }
            let transitive = scope == "compile" || scope == "runtime"
            if transitive && !managed.optional && !stack.contains(identity) {
                let children = childDependencies(
                    dependency, reactorModule: reactorModule, repository: repository, store: store
                )
                node.children = walk(
                    dependencies: children, depth: depth + 1, parentScope: scope,
                    exclusions: exclusions + managed.exclusions, management: management, reactor: reactor,
                    repository: repository, store: store, order: &order, stack: stack.union([identity])
                )
            }
            nodes.append(node)
        }
        return nodes
    }

    /// Direct dependencies keep an explicit version. Transitive ones take the root's
    /// `dependencyManagement` version and scope when it names them.
    private static func applyManagement(
        _ dependency: MavenDependency, management: [MavenDependency], transitive: Bool
    ) -> MavenDependency {
        guard let managed = management.first(where: {
            $0.groupId == dependency.groupId && $0.artifactId == dependency.artifactId
                && ($0.type.isEmpty || $0.type == dependency.type || dependency.type.isEmpty || $0.type == "jar")
                && ($0.classifier.isEmpty || $0.classifier == dependency.classifier)
        }) else { return dependency }
        var result = dependency
        if transitive || result.version.isEmpty, !managed.version.isEmpty { result.version = managed.version }
        if transitive || result.scope.isEmpty, !managed.scope.isEmpty, managed.scope != "import" {
            result.scope = managed.scope
        }
        if result.exclusions.isEmpty { result.exclusions = managed.exclusions }
        return result
    }

    /// The scope a dependency has from the module being resolved. `nil` means it is not visible.
    static func effectiveScope(declared: String, parent: String?) -> String? {
        let scope = declared.isEmpty ? "compile" : declared
        guard let parent else { return scope }
        switch scope {
        case "test", "provided", "system":
            return nil
        case "runtime":
            switch parent {
            case "runtime": return "runtime"
            case "compile": return "runtime"
            case "provided": return "provided"
            case "test": return "test"
            default: return "runtime"
            }
        default:
            return parent
        }
    }

    private static func resolveVersion(
        _ dependency: MavenDependency, repository: URL, reactor: [String: MavenEffectiveModule]
    ) -> String {
        if let module = reactorModule(for: dependency, reactor: reactor), !module.gav.version.isEmpty {
            if dependency.version.isEmpty || isRange(dependency.version) { return module.gav.version }
        }
        guard isRange(dependency.version) else { return dependency.version }
        let installed = MavenLocalRepository.installedVersions(
            groupId: dependency.groupId, artifactId: dependency.artifactId, repository: repository
        )
        return MavenVersion.highest(among: installed, matching: dependency.version) ?? dependency.version
    }

    private static func isRange(_ version: String) -> Bool {
        version.contains("[") || version.contains("(") || version.contains(",")
    }

    private static func reactorModule(for dependency: MavenDependency, reactor: [String: MavenEffectiveModule]) -> MavenEffectiveModule? {
        guard let module = reactor[dependency.groupId + ":" + dependency.artifactId] else { return nil }
        if dependency.version.isEmpty || isRange(dependency.version) { return module }
        if dependency.version == module.gav.version { return module }
        return nil
    }

    private static func childDependencies(
        _ dependency: MavenDependency,
        reactorModule: MavenEffectiveModule?,
        repository: URL,
        store: MavenPOMStore
    ) -> [MavenDependency] {
        if let reactorModule { return reactorModule.dependencies }
        guard dependency.resolvedType == "pom" || dependency.fileExtension == "jar" || dependency.type == "jar" else {
            return []
        }
        guard let url = MavenLocalRepository.artifactURL(
            groupId: dependency.groupId, artifactId: dependency.artifactId, version: dependency.version,
            extension: "pom", repository: repository
        ), let pom = try? store.pom(at: url) else { return [] }
        return pom.dependencies.map { declared in
            var copy = declared
            if copy.version.isEmpty, let managed = pom.dependencyManagement.first(where: {
                $0.groupId == copy.groupId && $0.artifactId == copy.artifactId
            }) {
                copy.version = managed.version
                if copy.scope == "compile", !managed.scope.isEmpty, managed.scope != "import" { copy.scope = managed.scope }
            }
            if copy.version.isEmpty { copy.version = dependency.version }
            return copy
        }
    }

    private static func artifactFile(_ dependency: MavenDependency, repository: URL) -> URL? {
        if dependency.scope == "system", !dependency.systemPath.isEmpty {
            return URL(fileURLWithPath: dependency.systemPath)
        }
        if dependency.resolvedType == "pom" { return nil }
        return MavenLocalRepository.artifactURL(
            groupId: dependency.groupId, artifactId: dependency.artifactId, version: dependency.version,
            classifier: dependency.resolvedClassifier, extension: dependency.fileExtension, repository: repository
        )
    }

    /// Nearest wins. At the same depth the first declaration wins. The root's dependency management
    /// then replaces the chosen version.
    private static func mediate(
        _ nodes: [MavenResolvedNode],
        management: [MavenDependency],
        repository: URL,
        reactor: [String: MavenEffectiveModule]
    ) -> [MavenResolvedNode] {
        var best: [String: (depth: Int, order: Int)] = [:]
        func consider(_ node: MavenResolvedNode) {
            let key = node.dependency.mediationKey
            if let current = best[key] {
                if node.depth < current.depth || (node.depth == current.depth && node.order < current.order) {
                    best[key] = (node.depth, node.order)
                }
            } else {
                best[key] = (node.depth, node.order)
            }
            for child in node.children { consider(child) }
        }
        for node in nodes { consider(node) }
        func mark(_ node: MavenResolvedNode) -> MavenResolvedNode {
            var copy = node
            let key = node.dependency.mediationKey
            if let winner = best[key], winner.depth != node.depth || winner.order != node.order {
                copy.omitted = true
            } else if let managed = management.first(where: {
                $0.groupId == node.dependency.groupId && $0.artifactId == node.dependency.artifactId && !$0.version.isEmpty
                    && $0.scope != "import"
            }), node.depth > 1 {
                copy.dependency.version = managed.version
                if !managed.scope.isEmpty { copy.scope = managed.scope }
                if copy.projectPath == nil {
                    copy.file = artifactFile(copy.dependency, repository: repository)
                    copy.missing = copy.file == nil && copy.dependency.scope != "system" && copy.dependency.resolvedType != "pom"
                }
            }
            copy.children = node.children.map(mark)
            return copy
        }
        return nodes.map(mark)
    }

    private static func classpaths(
        _ nodes: [MavenResolvedNode],
        module: MavenEffectiveModule,
        repository: URL,
        reactor: [String: MavenEffectiveModule]
    ) -> MavenResolution {
        var compileJars: [URL] = []
        var runtimeJars: [URL] = []
        var testJars: [URL] = []
        var compileProjects: [MavenProjectEdge] = []
        var runtimeProjects: [MavenProjectEdge] = []
        var testProjects: [MavenProjectEdge] = []
        var missing: [MavenDependency] = []
        var seenJars = Set<String>()
        var seenProjects = Set<String>()

        func addJar(_ url: URL, scopes visibility: ClasspathVisibility) {
            let key = url.standardizedFileURL.path
            guard seenJars.insert(key).inserted else { return }
            if visibility.compile { compileJars.append(url) }
            if visibility.runtime { runtimeJars.append(url) }
            if visibility.test { testJars.append(url) }
        }
        func addProject(_ edge: MavenProjectEdge, visibility: ClasspathVisibility) {
            let key = edge.projectPath + ":" + edge.sourceSetName
            guard seenProjects.insert(key).inserted else { return }
            if visibility.compile { compileProjects.append(edge) }
            if visibility.runtime { runtimeProjects.append(edge) }
            if visibility.test { testProjects.append(edge) }
        }
        func visit(_ node: MavenResolvedNode) {
            guard !node.omitted else { return }
            let visibility = classpathVisibility(for: node.scope)
            if let path = node.projectPath {
                addProject(MavenProjectEdge(projectPath: path, sourceSetName: node.sourceSetName), visibility: visibility)
            } else if let file = node.file {
                addJar(file, scopes: visibility)
            } else if node.missing {
                missing.append(node.dependency)
            }
            for child in node.children { visit(child) }
        }
        for node in nodes { visit(node) }
        let processors = module.annotationProcessors.compactMap { dependency -> URL? in
            var copy = dependency
            if copy.version.isEmpty {
                copy.version = module.dependencyManagement.first {
                    $0.groupId == copy.groupId && $0.artifactId == copy.artifactId
                }?.version ?? ""
            }
            return artifactFile(copy, repository: repository)
        }
        return MavenResolution(
            compileJars: compileJars, runtimeJars: runtimeJars, testJars: testJars,
            compileProjects: compileProjects, runtimeProjects: runtimeProjects, testProjects: testProjects,
            processorJars: processors, tree: nodes, missing: missing
        )
    }

    /// `main` compile is compile + provided + system. Runtime is compile + runtime. Test is every scope.
    private static func classpathVisibility(for scope: String) -> ClasspathVisibility {
        switch scope {
        case "provided", "system": return ClasspathVisibility(compile: true, runtime: false, test: true)
        case "runtime": return ClasspathVisibility(compile: false, runtime: true, test: true)
        case "test": return ClasspathVisibility(compile: false, runtime: false, test: true)
        default: return ClasspathVisibility(compile: true, runtime: true, test: true)
        }
    }
}

private struct ClasspathVisibility {
    var compile: Bool
    var runtime: Bool
    var test: Bool
}
