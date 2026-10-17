import Foundation

/// A Maven group, artifact and version. Empty strings mean the POM has not said yet (a child
/// inherits `groupId` and `version` from its parent).
public struct MavenGAV: Hashable, Sendable, Codable {
    public var groupId: String
    public var artifactId: String
    public var version: String

    public init(groupId: String = "", artifactId: String = "", version: String = "") {
        self.groupId = groupId
        self.artifactId = artifactId
        self.version = version
    }

    public var isComplete: Bool {
        !groupId.isEmpty && !artifactId.isEmpty && !version.isEmpty
    }

    /// `group:artifact:version`.
    public var coordinate: String { "\(groupId):\(artifactId):\(version)" }
}

/// One dependency or one `dependencyManagement` entry, as the POM wrote it.
public struct MavenDependency: Hashable, Sendable, Codable {
    public var groupId: String
    public var artifactId: String
    public var version: String
    /// `jar` when the POM omits it. `pom` for a BOM, `test-jar` for the tests classifier.
    public var type: String
    public var classifier: String
    /// `compile` when the POM omits it.
    public var scope: String
    public var optional: Bool
    public var systemPath: String
    public var exclusions: [MavenExclusion]

    public init(
        groupId: String,
        artifactId: String,
        version: String = "",
        type: String = "jar",
        classifier: String = "",
        scope: String = "compile",
        optional: Bool = false,
        systemPath: String = "",
        exclusions: [MavenExclusion] = []
    ) {
        self.groupId = groupId
        self.artifactId = artifactId
        self.version = version
        self.type = type
        self.classifier = classifier
        self.scope = scope
        self.optional = optional
        self.systemPath = systemPath
        self.exclusions = exclusions
    }

    /// Identity Maven mediates on: group, artifact, type and classifier. Version is what mediation chooses.
    public var mediationKey: String {
        "\(groupId):\(artifactId):\(type.isEmpty ? "jar" : type):\(classifier)"
    }

    /// `test-jar` is the `tests` classifier of the jar.
    public var resolvedClassifier: String {
        if !classifier.isEmpty { return classifier }
        return type == "test-jar" ? "tests" : ""
    }

    public var resolvedType: String {
        type == "test-jar" ? "jar" : (type.isEmpty ? "jar" : type)
    }

    public var fileExtension: String {
        switch resolvedType {
        case "pom": return "pom"
        case "jar", "test-jar": return "jar"
        default: return resolvedType
        }
    }
}

public struct MavenExclusion: Hashable, Sendable, Codable {
    public var groupId: String
    public var artifactId: String

    public init(groupId: String, artifactId: String) {
        self.groupId = groupId
        self.artifactId = artifactId
    }

    public func matches(group: String, artifact: String) -> Bool {
        (groupId == "*" || groupId == group) && (artifactId == "*" || artifactId == artifact)
    }
}

public struct MavenRepository: Hashable, Sendable, Codable {
    public var id: String
    public var url: String
    public var releases: Bool
    public var snapshots: Bool

    public init(id: String, url: String, releases: Bool = true, snapshots: Bool = true) {
        self.id = id
        self.url = url
        self.releases = releases
        self.snapshots = snapshots
    }
}

/// A plugin, with the goals its executions declare. `configuration` stays a small element tree:
/// compiler paths and Surefire's `argLine` are read from it later.
public struct MavenPlugin: Hashable, Sendable, Codable {
    public var groupId: String
    public var artifactId: String
    public var version: String
    public var goals: [String]
    public var configuration: MavenXMLElement?

    public init(
        groupId: String = "org.apache.maven.plugins",
        artifactId: String,
        version: String = "",
        goals: [String] = [],
        configuration: MavenXMLElement? = nil
    ) {
        self.groupId = groupId
        self.artifactId = artifactId
        self.version = version
        self.goals = goals
        self.configuration = configuration
    }

    public var key: String { "\(groupId):\(artifactId)" }
}

/// One element of a POM, kept for the parts that are not worth a dedicated field (`configuration`).
public struct MavenXMLElement: Hashable, Sendable, Codable {
    public var name: String
    public var text: String
    public var children: [MavenXMLElement]
    public var line: Int

    public init(name: String, text: String = "", children: [MavenXMLElement] = [], line: Int = 0) {
        self.name = name
        self.text = text
        self.children = children
        self.line = line
    }

    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func child(_ name: String) -> MavenXMLElement? {
        children.first { $0.name == name }
    }

    public func children(named name: String) -> [MavenXMLElement] {
        children.filter { $0.name == name }
    }

    /// Every trimmed text of `name` descendants one level down, or of this element when it is a leaf.
    public func values(named name: String) -> [String] {
        children(named: name).map(\.trimmedText).filter { !$0.isEmpty }
    }
}

public struct MavenProfile: Hashable, Sendable, Codable {
    public var id: String
    public var activation: MavenProfileActivation
    public var properties: [String: String]
    public var modules: [String]
    public var dependencies: [MavenDependency]
    public var dependencyManagement: [MavenDependency]
    public var repositories: [MavenRepository]
    public var plugins: [MavenPlugin]

    public init(
        id: String,
        activation: MavenProfileActivation = MavenProfileActivation(),
        properties: [String: String] = [:],
        modules: [String] = [],
        dependencies: [MavenDependency] = [],
        dependencyManagement: [MavenDependency] = [],
        repositories: [MavenRepository] = [],
        plugins: [MavenPlugin] = []
    ) {
        self.id = id
        self.activation = activation
        self.properties = properties
        self.modules = modules
        self.dependencies = dependencies
        self.dependencyManagement = dependencyManagement
        self.repositories = repositories
        self.plugins = plugins
    }
}

public struct MavenProfileActivation: Hashable, Sendable, Codable {
    public var activeByDefault: Bool
    public var jdk: String
    /// Property name. A leading `!` means the property must be absent.
    public var propertyName: String
    public var propertyValue: String?
    public var osFamily: String
    public var osName: String
    public var fileExists: String
    public var fileMissing: String

    public init(
        activeByDefault: Bool = false,
        jdk: String = "",
        propertyName: String = "",
        propertyValue: String? = nil,
        osFamily: String = "",
        osName: String = "",
        fileExists: String = "",
        fileMissing: String = ""
    ) {
        self.activeByDefault = activeByDefault
        self.jdk = jdk
        self.propertyName = propertyName
        self.propertyValue = propertyValue
        self.osFamily = osFamily
        self.osName = osName
        self.fileExists = fileExists
        self.fileMissing = fileMissing
    }

    public var isEmpty: Bool {
        !activeByDefault && jdk.isEmpty && propertyName.isEmpty && osFamily.isEmpty && osName.isEmpty
            && fileExists.isEmpty && fileMissing.isEmpty
    }
}

/// A POM as the file wrote it, before inheritance, profiles and interpolation.
public struct MavenPOM: Sendable {
    public var file: URL
    public var line: Int
    public var parent: MavenGAV?
    /// `nil` when the POM omits it (the default is `../pom.xml`). Empty means "do not look on disk".
    public var parentRelativePath: String?
    public var gav: MavenGAV
    public var packaging: String
    public var properties: [String: String]
    public var modules: [String]
    public var dependencies: [MavenDependency]
    public var dependencyManagement: [MavenDependency]
    public var repositories: [MavenRepository]
    public var directory: String
    public var sourceDirectory: String
    public var testSourceDirectory: String
    public var outputDirectory: String
    public var testOutputDirectory: String
    public var plugins: [MavenPlugin]
    public var pluginManagement: [MavenPlugin]
    public var profiles: [MavenProfile]

    public init(
        file: URL,
        line: Int = 1,
        parent: MavenGAV? = nil,
        parentRelativePath: String? = nil,
        gav: MavenGAV = MavenGAV(),
        packaging: String = "",
        properties: [String: String] = [:],
        modules: [String] = [],
        dependencies: [MavenDependency] = [],
        dependencyManagement: [MavenDependency] = [],
        repositories: [MavenRepository] = [],
        directory: String = "",
        sourceDirectory: String = "",
        testSourceDirectory: String = "",
        outputDirectory: String = "",
        testOutputDirectory: String = "",
        plugins: [MavenPlugin] = [],
        pluginManagement: [MavenPlugin] = [],
        profiles: [MavenProfile] = []
    ) {
        self.file = file
        self.line = line
        self.parent = parent
        self.parentRelativePath = parentRelativePath
        self.gav = gav
        self.packaging = packaging
        self.properties = properties
        self.modules = modules
        self.dependencies = dependencies
        self.dependencyManagement = dependencyManagement
        self.repositories = repositories
        self.directory = directory
        self.sourceDirectory = sourceDirectory
        self.testSourceDirectory = testSourceDirectory
        self.outputDirectory = outputDirectory
        self.testOutputDirectory = testOutputDirectory
        self.plugins = plugins
        self.pluginManagement = pluginManagement
        self.profiles = profiles
    }
}

/// Why a POM could not be read. `line` is 1-based when the parser knows it.
public struct MavenReadError: Error, Equatable, Sendable, LocalizedError {
    public var file: URL
    public var line: Int?
    public var message: String

    public init(file: URL, line: Int? = nil, message: String) {
        self.file = file
        self.line = line
        self.message = message
    }

    public var errorDescription: String? {
        if let line {
            return "\(file.path):\(line): \(message)"
        }
        return "\(file.path): \(message)"
    }
}
