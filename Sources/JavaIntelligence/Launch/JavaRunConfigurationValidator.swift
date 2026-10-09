import Foundation

/// What is wrong with a run configuration, found without launching it: the red cross in the
/// picker and the messages in the Edit Configurations form.
public enum JavaRunConfigurationValidator {
    /// The form field a problem belongs to.
    public enum Field: String, Sendable {
        case target, sourceFile, workingDirectory, jdk, redirectInput, beforeLaunch
    }

    public struct Problem: Equatable, Sendable {
        public let field: Field
        public let message: String

        public init(field: Field, message: String) {
            self.field = field
            self.message = message
        }
    }

    /// What the checks look at besides the configuration itself.
    public struct Context: Sendable {
        public var projectRoot: URL?
        /// `nil` until a Gradle sync has finished: checks that need the model are skipped.
        public var gradleModel: JavaGradleProjectModel?
        /// The project's other configurations, which a before-launch step may name.
        public var configurations: [JavaRunConfiguration]
        public var fileExists: @Sendable (String) -> Bool
        public var directoryExists: @Sendable (String) -> Bool
        /// The feature version of the JDK the configuration will run on, when known.
        public var jdkFeatureVersion: Int?

        public init(
            projectRoot: URL? = nil,
            gradleModel: JavaGradleProjectModel? = nil,
            configurations: [JavaRunConfiguration] = [],
            jdkFeatureVersion: Int? = nil,
            fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
            directoryExists: @escaping @Sendable (String) -> Bool = {
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue
            }
        ) {
            self.projectRoot = projectRoot
            self.gradleModel = gradleModel
            self.configurations = configurations
            self.jdkFeatureVersion = jdkFeatureVersion
            self.fileExists = fileExists
            self.directoryExists = directoryExists
        }
    }

    private static let binaryName = #"^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)*$"#

    public static func problems(for configuration: JavaRunConfiguration, context: Context) -> [Problem] {
        var problems: [Problem] = []
        func add(_ field: Field, _ message: String) { problems.append(Problem(field: field, message: message)) }

        switch configuration.target {
        case .gradleRun(let projectPath, let taskName):
            if context.projectRoot == nil { add(.target, "A Gradle run needs an open project folder.") }
            if let subproject = subproject(projectPath, in: context) {
                let task = taskName ?? "run"
                if !subproject.tasks.isEmpty, !subproject.tasks.contains(where: { $0.name == task }) {
                    add(.target, "\(projectPath == ":" ? "The root project" : projectPath) has no task named “\(task)”.")
                }
            } else if context.gradleModel != nil {
                add(.target, "There is no Gradle project “\(projectPath)”.")
            }
        case .singleFile(let path):
            if !path.hasSuffix(".java") {
                add(.target, "Choose a .java file.")
            } else if !context.fileExists(path) {
                add(.target, "\((path as NSString).lastPathComponent) does not exist.")
            }
        case .classpathMain(let className, let sourceFile):
            if className.range(of: binaryName, options: .regularExpression) == nil {
                add(.target, className.isEmpty ? "Choose a main class." : "“\(className)” is not a class name.")
            }
            if !sourceFile.hasSuffix(".java") {
                add(.sourceFile, "Choose the source file of the class.")
            } else if !context.fileExists(sourceFile) {
                add(.sourceFile, "\((sourceFile as NSString).lastPathComponent) does not exist.")
            } else if let model = context.gradleModel, model.runtimeClasspath(forFile: URL(fileURLWithPath: sourceFile)) == nil {
                add(.sourceFile, "\((sourceFile as NSString).lastPathComponent) is not in a Gradle source set.")
            }
        case .gradleTest(let taskPath, _, let sourceFile):
            if context.projectRoot == nil { add(.target, "Tests run through Gradle and need an open project folder.") }
            let parts = taskPath.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if parts.count < 2 || parts.last?.isEmpty != false {
                add(.target, "“\(taskPath)” is not a Gradle task path.")
            } else if context.gradleModel != nil {
                let projectPath = parts.dropLast().joined(separator: ":")
                if let subproject = subproject(projectPath.isEmpty ? ":" : projectPath, in: context) {
                    if !subproject.tasks.isEmpty, !subproject.tasks.contains(where: { $0.path == taskPath }) {
                        add(.target, "There is no task “\(taskPath)”.")
                    }
                } else {
                    add(.target, "There is no Gradle project “\(projectPath.isEmpty ? ":" : projectPath)”.")
                }
            }
            if let sourceFile, !context.fileExists(sourceFile) {
                add(.target, "\((sourceFile as NSString).lastPathComponent) does not exist.")
            }
        }

        if configuration.supportsWorkingDirectory {
            if let directory = configuration.workingDirectory, !directory.isEmpty, !context.directoryExists(directory) {
                add(.workingDirectory, "The working directory does not exist.")
            }
            if let input = configuration.redirectInputPath, !input.isEmpty, !context.fileExists(input) {
                add(.redirectInput, "The input file does not exist.")
            }
        }
        if let home = configuration.jdkHome, !home.isEmpty, !context.fileExists(home + "/bin/java") {
            add(.jdk, "The chosen JDK is gone.")
        }
        if let version = context.jdkFeatureVersion, version < 8 {
            add(.jdk, "Java \(version) is too old to run this.")
        }
        for task in configuration.beforeLaunch {
            switch task {
            case .gradleTasks(let tasks):
                if tasks.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    add(.beforeLaunch, "A Gradle step has no task.")
                }
            case .runConfiguration(let id):
                if id == configuration.id {
                    add(.beforeLaunch, "A configuration cannot run itself first.")
                } else if let other = context.configurations.first(where: { $0.id == id }) {
                    if dependsOn(other, id: configuration.id, in: context.configurations) {
                        add(.beforeLaunch, "“\(other.displayName)” runs this configuration first, so they wait on each other.")
                    }
                } else {
                    add(.beforeLaunch, "A configuration it runs first was deleted.")
                }
            }
        }
        return problems
    }

    private static func subproject(_ path: String, in context: Context) -> JavaGradleProjectModel.Subproject? {
        context.gradleModel?.subprojects.first { $0.path == path }
    }

    /// Whether `configuration`, followed through its before-launch steps, reaches `id`.
    private static func dependsOn(_ configuration: JavaRunConfiguration, id: UUID, in all: [JavaRunConfiguration]) -> Bool {
        var visited = Set<UUID>()
        func walk(_ current: JavaRunConfiguration) -> Bool {
            guard visited.insert(current.id).inserted else { return false }
            for case .runConfiguration(let next) in current.beforeLaunch {
                if next == id { return true }
                if let found = all.first(where: { $0.id == next }), walk(found) { return true }
            }
            return false
        }
        return walk(configuration)
    }
}
