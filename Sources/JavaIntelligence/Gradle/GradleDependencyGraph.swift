import Foundation

/// A dependency graph of a Gradle build, in one of two forms that share this type: the **modules** of the
/// build and which depend on which (read from a synced ``JavaGradleProjectModel``, no Gradle run), or the
/// **libraries** one module resolves for a configuration (the output of ``GradleDependencyGraphScript``).
public struct GradleDependencyGraph: Codable, Sendable, Equatable {
    public enum ComponentKind: String, Codable, Sendable {
        /// A project of this build.
        case project
        /// A library from a repository.
        case module
        /// A dependency Gradle could not resolve.
        case unresolved
    }

    public struct Component: Codable, Hashable, Sendable, Identifiable {
        public var id: String { key }
        /// `group:name` for a library, `project:<path>` for a project, so two versions never coexist.
        public let key: String
        public let kind: ComponentKind
        public let group: String
        public let name: String
        public let version: String
        public let projectPath: String
        /// Gradle chose this version over another one requested somewhere in the graph.
        public let conflictResolved: Bool
        /// Why resolution failed, for ``ComponentKind/unresolved``.
        public let message: String

        public init(
            key: String, kind: ComponentKind, group: String = "", name: String, version: String = "",
            projectPath: String = "", conflictResolved: Bool = false, message: String = ""
        ) {
            self.key = key
            self.kind = kind
            self.group = group
            self.name = name
            self.version = version
            self.projectPath = projectPath
            self.conflictResolved = conflictResolved
            self.message = message
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            kind = try container.decodeIfPresent(ComponentKind.self, forKey: .kind) ?? .module
            group = try container.decodeIfPresent(String.self, forKey: .group) ?? ""
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? key
            version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
            projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath) ?? ""
            conflictResolved = try container.decodeIfPresent(Bool.self, forKey: .conflictResolved) ?? false
            message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        }

        /// `group:name` for a library, the project path for a project.
        public var coordinate: String {
            switch kind {
            case .project: projectPath.isEmpty ? name : projectPath
            case .module where !group.isEmpty: "\(group):\(name)"
            default: name
            }
        }
    }

    public struct Edge: Codable, Hashable, Sendable {
        public let from: String
        public let to: String
        /// Set when the dependency asked for another version than the one Gradle picked.
        public let requestedVersion: String?
        /// A dependency constraint rather than a declared dependency.
        public let constraint: Bool
        /// The module reaches the other only at runtime (`runtimeOnly`), not on its compile classpath.
        public let runtimeOnly: Bool

        public init(from: String, to: String, requestedVersion: String? = nil, constraint: Bool = false, runtimeOnly: Bool = false) {
            self.from = from
            self.to = to
            self.requestedVersion = requestedVersion
            self.constraint = constraint
            self.runtimeOnly = runtimeOnly
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            from = try container.decode(String.self, forKey: .from)
            to = try container.decode(String.self, forKey: .to)
            requestedVersion = try container.decodeIfPresent(String.self, forKey: .requestedVersion)
            constraint = try container.decodeIfPresent(Bool.self, forKey: .constraint) ?? false
            runtimeOnly = try container.decodeIfPresent(Bool.self, forKey: .runtimeOnly) ?? false
        }
    }

    public static let formatVersion = 1
    /// Most components a diagram draws; a larger graph is cut to the nearest ones.
    public static let componentLimit = 800

    public var formatVersion: Int
    public var gradleVersion: String
    /// The project the graph was resolved for (`:app`), or `:` for a module graph of the whole build.
    public var project: String
    /// The configuration resolved (`runtimeClasspath`); empty for a module graph.
    public var configuration: String
    public var rootKey: String
    public var components: [Component]
    public var edges: [Edge]
    /// Set by the script when the project has no such configuration or it could not be resolved.
    public var error: String?
    /// Components dropped by ``limited(to:)``.
    public var omittedCount: Int

    public var truncated: Bool { omittedCount > 0 }

    public init(
        formatVersion: Int = GradleDependencyGraph.formatVersion, gradleVersion: String = "", project: String = ":",
        configuration: String = "", rootKey: String = "", components: [Component] = [], edges: [Edge] = [],
        error: String? = nil, omittedCount: Int = 0
    ) {
        self.formatVersion = formatVersion
        self.gradleVersion = gradleVersion
        self.project = project
        self.configuration = configuration
        self.rootKey = rootKey
        self.components = components
        self.edges = edges
        self.error = error
        self.omittedCount = omittedCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.formatVersion
        gradleVersion = try container.decodeIfPresent(String.self, forKey: .gradleVersion) ?? ""
        project = try container.decodeIfPresent(String.self, forKey: .project) ?? ":"
        configuration = try container.decodeIfPresent(String.self, forKey: .configuration) ?? ""
        rootKey = try container.decodeIfPresent(String.self, forKey: .rootKey) ?? ""
        components = try container.decodeIfPresent([Component].self, forKey: .components) ?? []
        edges = try container.decodeIfPresent([Edge].self, forKey: .edges) ?? []
        error = try container.decodeIfPresent(String.self, forKey: .error)
        omittedCount = 0
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, gradleVersion, project, configuration, rootKey, components, edges, error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(gradleVersion, forKey: .gradleVersion)
        try container.encode(project, forKey: .project)
        try container.encode(configuration, forKey: .configuration)
        try container.encode(rootKey, forKey: .rootKey)
        try container.encode(components, forKey: .components)
        try container.encode(edges, forKey: .edges)
        try container.encodeIfPresent(error, forKey: .error)
    }

    // MARK: - Limiting

    /// The `limit` components nearest the root (breadth first), with only the edges between them.
    public func limited(to limit: Int = GradleDependencyGraph.componentLimit) -> GradleDependencyGraph {
        guard components.count > limit else { return self }
        var outgoing: [String: [String]] = [:]
        for edge in edges { outgoing[edge.from, default: []].append(edge.to) }
        let known = Set(components.map(\.key))
        var order: [String] = []
        var seen = Set<String>()
        var queue: [String] = known.contains(rootKey) ? [rootKey] : []
        if let first = queue.first { seen.insert(first) }
        var cursor = 0
        while cursor < queue.count, order.count < limit {
            let key = queue[cursor]
            cursor += 1
            order.append(key)
            for next in outgoing[key] ?? [] where known.contains(next) && seen.insert(next).inserted {
                queue.append(next)
            }
        }
        for component in components where order.count < limit && !seen.contains(component.key) {
            seen.insert(component.key)
            order.append(component.key)
        }
        let kept = Set(order)
        var result = self
        result.components = components.filter { kept.contains($0.key) }
        result.edges = edges.filter { kept.contains($0.from) && kept.contains($0.to) }
        result.omittedCount = components.count - kept.count
        return result
    }

    // MARK: - Module graph

    /// The projects of the build and the project-to-project dependencies of their `main` source sets,
    /// from a model that has already been synced.
    public static func moduleGraph(from model: JavaGradleProjectModel) -> GradleDependencyGraph {
        var components: [Component] = []
        var edges: [Edge] = []
        let paths = Set(model.subprojects.map(\.path))
        for subproject in model.subprojects.sorted(by: { $0.path < $1.path }) {
            let name = subproject.path == ":"
                ? subproject.directory.lastPathComponent
                : String(subproject.path.split(separator: ":").last ?? "")
            components.append(Component(
                key: key(forProject: subproject.path), kind: .project, name: name, projectPath: subproject.path
            ))
            guard let main = subproject.sourceSets.first(where: { $0.name == "main" }) else { continue }
            let compile = Set(main.projectDependencies.map(\.projectPath))
            var seen = Set<String>()
            for dependency in main.projectDependencies + main.runtimeProjectDependencies {
                let target = dependency.projectPath
                guard target != subproject.path, paths.contains(target), seen.insert(target).inserted else { continue }
                edges.append(Edge(
                    from: key(forProject: subproject.path), to: key(forProject: target), runtimeOnly: !compile.contains(target)
                ))
            }
        }
        let root = model.subprojects.contains { $0.path == ":" } ? ":" : (model.subprojects.first?.path ?? ":")
        return GradleDependencyGraph(
            gradleVersion: model.gradleVersion, project: ":", rootKey: key(forProject: root),
            components: components, edges: edges
        )
    }

    public static func key(forProject path: String) -> String { "project:" + path }
}
