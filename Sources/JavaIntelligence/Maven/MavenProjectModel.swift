import Foundation

/// A profile the model considered, and whether it was active for this read.
public struct MavenProfileState: Codable, Hashable, Sendable {
    public var id: String
    public var active: Bool

    public init(id: String, active: Bool) {
        self.id = id
        self.active = active
    }
}

/// One edge of the dependency tree shown in the Maven tool window.
public struct MavenDependencyNode: Codable, Sendable, Equatable {
    public var groupId: String
    public var artifactId: String
    public var version: String
    public var scope: String
    public var type: String
    public var classifier: String
    public var omitted: Bool
    public var missing: Bool
    public var projectPath: String?
    public var children: [MavenDependencyNode]

    public init(
        groupId: String, artifactId: String, version: String, scope: String, type: String = "jar",
        classifier: String = "", omitted: Bool = false, missing: Bool = false, projectPath: String? = nil,
        children: [MavenDependencyNode] = []
    ) {
        self.groupId = groupId
        self.artifactId = artifactId
        self.version = version
        self.scope = scope
        self.type = type
        self.classifier = classifier
        self.omitted = omitted
        self.missing = missing
        self.projectPath = projectPath
        self.children = children
    }

    public var coordinate: String {
        var text = "\(groupId):\(artifactId):\(version)"
        if !classifier.isEmpty { text += ":\(classifier)" }
        return text
    }
}

/// One Maven module after the reactor was read and its classpath resolved.
public struct MavenModule: Codable, Sendable, Equatable {
    public var path: String
    public var directory: URL
    public var groupId: String
    public var artifactId: String
    public var version: String
    public var packaging: String
    public var plugins: [MavenPlugin]
    public var dependencyTree: [MavenDependencyNode]
    public var sourceDirectories: [URL]
    public var testSourceDirectories: [URL]
    public var outputDirectory: URL
    public var testOutputDirectory: URL
    public var generatedSourceDirectories: [URL]
    public var languageLevel: Int?
    public var compileClasspathJars: [URL]
    public var runtimeClasspathJars: [URL]
    public var testClasspathJars: [URL]
    public var compileProjectDependencies: [MavenModuleDependency]
    public var runtimeProjectDependencies: [MavenModuleDependency]
    public var testProjectDependencies: [MavenModuleDependency]
    public var annotationProcessorJars: [URL]
    public var usesJacocoPrepareAgent: Bool
    public var surefireArgLine: String?
    /// `group:artifact`, the `-pl` selector.
    public var selector: String { "\(groupId):\(artifactId)" }

    public init(
        path: String, directory: URL, groupId: String, artifactId: String, version: String,
        packaging: String = "jar", plugins: [MavenPlugin] = [], dependencyTree: [MavenDependencyNode] = [],
        sourceDirectories: [URL] = [], testSourceDirectories: [URL] = [], outputDirectory: URL, testOutputDirectory: URL,
        generatedSourceDirectories: [URL] = [], languageLevel: Int? = nil,
        compileClasspathJars: [URL] = [], runtimeClasspathJars: [URL] = [], testClasspathJars: [URL] = [],
        compileProjectDependencies: [MavenModuleDependency] = [],
        runtimeProjectDependencies: [MavenModuleDependency] = [],
        testProjectDependencies: [MavenModuleDependency] = [],
        annotationProcessorJars: [URL] = [],
        usesJacocoPrepareAgent: Bool = false, surefireArgLine: String? = nil
    ) {
        self.path = path
        self.directory = directory
        self.groupId = groupId
        self.artifactId = artifactId
        self.version = version
        self.packaging = packaging
        self.plugins = plugins
        self.dependencyTree = dependencyTree
        self.sourceDirectories = sourceDirectories
        self.testSourceDirectories = testSourceDirectories
        self.outputDirectory = outputDirectory
        self.testOutputDirectory = testOutputDirectory
        self.generatedSourceDirectories = generatedSourceDirectories
        self.languageLevel = languageLevel
        self.compileClasspathJars = compileClasspathJars
        self.runtimeClasspathJars = runtimeClasspathJars
        self.testClasspathJars = testClasspathJars
        self.compileProjectDependencies = compileProjectDependencies
        self.runtimeProjectDependencies = runtimeProjectDependencies
        self.testProjectDependencies = testProjectDependencies
        self.annotationProcessorJars = annotationProcessorJars
        self.usesJacocoPrepareAgent = usesJacocoPrepareAgent
        self.surefireArgLine = surefireArgLine
    }
}

/// A reactor module on another module's classpath, and which of its source sets.
public struct MavenModuleDependency: Codable, Hashable, Sendable {
    public var projectPath: String
    public var sourceSetName: String

    public init(projectPath: String, sourceSetName: String) {
        self.projectPath = projectPath
        self.sourceSetName = sourceSetName
    }
}

/// The result of reading a Maven reactor without running Maven.
public struct MavenProjectModel: Codable, Sendable, Equatable {
    public var modules: [MavenModule]
    public var profiles: [MavenProfileState]
    public var repositories: [MavenRepository]
    public var missing: [MavenDependency]
    public var unresolved: [String]

    public init(
        modules: [MavenModule], profiles: [MavenProfileState], repositories: [MavenRepository],
        missing: [MavenDependency], unresolved: [String]
    ) {
        self.modules = modules
        self.profiles = profiles
        self.repositories = repositories
        self.missing = missing
        self.unresolved = unresolved
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modules = try container.decode([MavenModule].self, forKey: .modules)
        profiles = try container.decodeIfPresent([MavenProfileState].self, forKey: .profiles) ?? []
        repositories = try container.decodeIfPresent([MavenRepository].self, forKey: .repositories) ?? []
        missing = try container.decodeIfPresent([MavenDependency].self, forKey: .missing) ?? []
        unresolved = try container.decodeIfPresent([String].self, forKey: .unresolved) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modules, forKey: .modules)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(repositories, forKey: .repositories)
        try container.encode(missing, forKey: .missing)
        try container.encode(unresolved, forKey: .unresolved)
    }

    private enum CodingKeys: String, CodingKey {
        case modules, profiles, repositories, missing, unresolved
    }

    /// The same shape Gradle sync produces, so indexing, `javac` and the runtime classpath stay unchanged.
    public var javaProjectModel: JavaGradleProjectModel {
        let subprojects = modules.map { module -> JavaGradleProjectModel.Subproject in
            let main = JavaGradleProjectModel.SourceSet(
                name: "main",
                sourceDirs: module.sourceDirectories,
                outputDirs: [module.outputDirectory],
                compileClasspathJars: module.compileClasspathJars,
                projectDependencies: module.compileProjectDependencies.map(Self.projectDependency),
                runtimeClasspathJars: module.runtimeClasspathJars,
                runtimeProjectDependencies: module.runtimeProjectDependencies.map(Self.projectDependency),
                generatedSourceDirs: module.generatedSourceDirectories,
                annotationProcessorJars: module.annotationProcessorJars
            )
            let ownMain = JavaGradleProjectModel.ProjectDependency(projectPath: module.path, sourceSetName: "main")
            let testProjects = [ownMain] + module.testProjectDependencies.map(Self.projectDependency)
            let test = JavaGradleProjectModel.SourceSet(
                name: "test",
                sourceDirs: module.testSourceDirectories,
                outputDirs: [module.testOutputDirectory, module.outputDirectory],
                compileClasspathJars: module.testClasspathJars,
                projectDependencies: testProjects,
                runtimeClasspathJars: module.testClasspathJars,
                runtimeProjectDependencies: testProjects,
                generatedSourceDirs: [],
                annotationProcessorJars: module.annotationProcessorJars
            )
            let testTask = JavaGradleProjectModel.GradleTestTask(
                path: module.path == ":" ? ":test" : "\(module.path):test",
                name: "test",
                sourceSetName: "test",
                resultsDir: module.directory.appendingPathComponent("target/surefire-reports", isDirectory: true)
            )
            return JavaGradleProjectModel.Subproject(
                path: module.path,
                directory: module.directory,
                languageLevel: module.languageLevel,
                sourceSets: [main, test],
                tasks: Self.lifecycleTasks(modulePath: module.path),
                testTasks: [testTask]
            )
        }
        return JavaGradleProjectModel(formatVersion: 8, gradleVersion: "maven", subprojects: subprojects, unresolved: unresolved)
    }

    /// The library graph of one module, from the native tree. No Maven process runs.
    public func dependencyGraph(modulePath: String = ":", limit: Int = GradleDependencyGraph.componentLimit) -> GradleDependencyGraph {
        let module = modules.first { $0.path == modulePath } ?? modules.first
        let rootKey = module.map { "project:\($0.path)" } ?? "project::"
        var components: [GradleDependencyGraph.Component] = []
        var edges: [GradleDependencyGraph.Edge] = []
        var seen = Set<String>()
        if let module {
            components.append(GradleDependencyGraph.Component(
                key: rootKey, kind: .project, name: module.artifactId, projectPath: module.path
            ))
            seen.insert(rootKey)
            func walk(_ nodes: [MavenDependencyNode], parent: String) {
                for node in nodes where !node.omitted {
                    let key = node.projectPath.map { "project:\($0)" } ?? "\(node.groupId):\(node.artifactId)"
                    if seen.insert(key).inserted {
                        components.append(GradleDependencyGraph.Component(
                            key: key,
                            kind: node.missing ? .unresolved : (node.projectPath == nil ? .module : .project),
                            group: node.groupId,
                            name: node.artifactId,
                            version: node.version,
                            projectPath: node.projectPath ?? "",
                            message: node.missing ? "Not in the local repository" : ""
                        ))
                    }
                    edges.append(GradleDependencyGraph.Edge(
                        from: parent, to: key, runtimeOnly: node.scope == "runtime" || node.scope == "test"
                    ))
                    walk(node.children, parent: key)
                }
            }
            walk(module.dependencyTree, parent: rootKey)
        }
        return GradleDependencyGraph(
            gradleVersion: "maven", project: modulePath, configuration: "compile", rootKey: rootKey,
            components: components, edges: edges
        ).limited(to: limit)
    }

    private static func projectDependency(_ edge: MavenModuleDependency) -> JavaGradleProjectModel.ProjectDependency {
        JavaGradleProjectModel.ProjectDependency(projectPath: edge.projectPath, sourceSetName: edge.sourceSetName)
    }

    private static func lifecycleTasks(modulePath: String) -> [JavaGradleProjectModel.GradleTask] {
        let goals = ["clean", "validate", "compile", "test", "package", "verify", "install", "deploy"]
        return goals.map { goal in
            let path = modulePath == ":" ? ":\(goal)" : "\(modulePath):\(goal)"
            return JavaGradleProjectModel.GradleTask(path: path, name: goal, group: "lifecycle", description: goal)
        }
    }
}

extension MavenProjectModel {
    static func node(from resolved: MavenResolvedNode) -> MavenDependencyNode {
        MavenDependencyNode(
            groupId: resolved.dependency.groupId,
            artifactId: resolved.dependency.artifactId,
            version: resolved.dependency.version,
            scope: resolved.scope,
            type: resolved.dependency.type,
            classifier: resolved.dependency.resolvedClassifier,
            omitted: resolved.omitted,
            missing: resolved.missing,
            projectPath: resolved.projectPath,
            children: resolved.children.map(node(from:))
        )
    }
}
