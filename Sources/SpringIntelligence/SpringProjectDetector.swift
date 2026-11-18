import Foundation
import JavaIntelligence

public enum SpringFeature: String, Hashable, Sendable, CaseIterable {
    case framework, boot, mvc, webflux, dataJPA, dataJDBC, security, validation, actuator, batch, integration, cloud, cloudConfig
}

/// One build module that uses Spring, with what its classpath says about it.
public struct SpringModuleInfo: Hashable, Sendable {
    public let projectPath: String
    public let directory: URL
    public let frameworkVersion: String?
    public let bootVersion: String?
    public let features: Set<SpringFeature>
    /// Main-source-set Java roots; the only files the Spring model reads for this module.
    public let sourceRoots: [URL]
    /// `src/main/resources` next to a `…/java` source root, when it exists on disk.
    public let resourceRoots: [URL]
    /// Compile and runtime jars of the main source set, where Spring Boot's configuration metadata lives.
    public let classpathJars: [URL]
    /// Compiled output folders of the main source set (generated `META-INF/spring-configuration-metadata.json`).
    public let outputDirs: [URL]
    /// Project paths this module's main source set depends on, transitively (compile and runtime project dependencies).
    public let dependencyPaths: Set<String>
    /// False for a module that only sits in a Spring module's dependency closure (a plain `domain` or `api` module):
    /// its sources are read so types resolve across the boundary, but it has no Spring jar of its own.
    public let isSpring: Bool

    public init(projectPath: String, directory: URL, frameworkVersion: String?, bootVersion: String?, features: Set<SpringFeature>,
                sourceRoots: [URL], resourceRoots: [URL], classpathJars: [URL], outputDirs: [URL], dependencyPaths: Set<String>, isSpring: Bool) {
        self.projectPath = projectPath; self.directory = directory; self.frameworkVersion = frameworkVersion; self.bootVersion = bootVersion
        self.features = features; self.sourceRoots = sourceRoots; self.resourceRoots = resourceRoots; self.classpathJars = classpathJars
        self.outputDirs = outputDirs; self.dependencyPaths = dependencyPaths; self.isSpring = isSpring
    }
}

/// Spring detection from the build model Umbra already has (Gradle, or Maven projected into the same
/// shape). It looks at jar coordinates only; nothing is read from disk but directory existence for
/// resource roots, so a non-Spring project costs one pass over its jar names.
///
/// Spring Scheduling, Cache and `@Async` live in `spring-context`, so they are not separate features.
public enum SpringProjectDetector {
    private static let artifactFeatures: [String: SpringFeature] = [
        "spring-webmvc": .mvc, "spring-webflux": .webflux,
        "spring-data-jpa": .dataJPA, "spring-data-jdbc": .dataJDBC,
        "spring-security-core": .security, "spring-security-web": .security, "spring-security-config": .security,
        "hibernate-validator": .validation, "jakarta.validation-api": .validation,
        "spring-boot-actuator": .actuator, "spring-batch-core": .batch, "spring-integration-core": .integration,
        "spring-cloud-context": .cloud, "spring-cloud-commons": .cloud, "spring-cloud-config-client": .cloudConfig,
    ]

    /// Spring modules, then the modules they depend on that are not Spring modules themselves (so their types resolve).
    /// A project without Spring returns `[]`: nothing outside the Spring modules' closure is ever read.
    public static func detect(in model: JavaGradleProjectModel) -> [SpringModuleInfo] {
        var graph: [String: Set<String>] = [:]
        for sub in model.subprojects {
            var direct = Set<String>()
            for set in sub.sourceSets where set.name == "main" {
                direct.formUnion(set.projectDependencies.map(\.projectPath))
                direct.formUnion(set.runtimeProjectDependencies.map(\.projectPath))
            }
            direct.remove(sub.path)
            graph[sub.path] = direct
        }
        func closure(of path: String) -> Set<String> {
            var seen = Set<String>(), stack = Array(graph[path] ?? [])
            while let next = stack.popLast() {
                if seen.insert(next).inserted { stack.append(contentsOf: graph[next] ?? []) }
            }
            seen.remove(path)
            return seen
        }
        let spring: [SpringModuleInfo] = model.subprojects.compactMap { sub in
            guard let main = sub.sourceSets.first(where: { $0.name == "main" }) else { return nil }
            return springInfo(for: sub, main: main, dependencyPaths: closure(of: sub.path))
        }
        guard !spring.isEmpty else { return [] }
        let known = Set(spring.map(\.projectPath))
        let needed = Set(spring.flatMap(\.dependencyPaths)).subtracting(known)
        let plain: [SpringModuleInfo] = model.subprojects.compactMap { sub in
            guard needed.contains(sub.path), let main = sub.sourceSets.first(where: { $0.name == "main" }) else { return nil }
            return SpringModuleInfo(
                projectPath: sub.path, directory: sub.directory, frameworkVersion: nil, bootVersion: nil, features: [],
                sourceRoots: main.sourceDirs.filter { !main.generatedSourceDirs.contains($0) }, resourceRoots: [],
                classpathJars: [], outputDirs: [], dependencyPaths: closure(of: sub.path), isSpring: false)
        }
        return spring + plain
    }

    private static func springInfo(for sub: JavaGradleProjectModel.Subproject, main: JavaGradleProjectModel.SourceSet, dependencyPaths: Set<String>) -> SpringModuleInfo? {
            var features: Set<SpringFeature> = []
            var framework: String?, boot: String?
            for jar in main.compileClasspathJars + main.runtimeClasspathJars {
                let c = JavaLibraryCoordinates.parse(jar: jar)
                let isSpring = c.group.hasPrefix("org.springframework") || c.group.hasPrefix("org.hibernate.validator")
                    || c.group == "jakarta.validation"
                guard isSpring else { continue }
                if c.group == "org.springframework.boot" {
                    if c.artifact == "spring-boot" { features.insert(.boot); boot = boot ?? c.version }
                    if c.artifact == "spring-boot-actuator" { features.insert(.actuator) }
                }
                if c.group == "org.springframework", c.artifact == "spring-context" || c.artifact == "spring-beans" || c.artifact == "spring-core" {
                    features.insert(.framework); framework = framework ?? c.version
                }
                if let f = artifactFeatures[c.artifact] { features.insert(f) }
            }
            guard features.contains(.framework) || features.contains(.boot) else { return nil }
            let roots = main.sourceDirs.filter { !main.generatedSourceDirs.contains($0) }
            let resources = roots.compactMap { dir -> URL? in
                guard dir.lastPathComponent == "java" else { return nil }
                let r = dir.deletingLastPathComponent().appendingPathComponent("resources", isDirectory: true)
                return FileManager.default.fileExists(atPath: r.path) ? r : nil
            }
            return SpringModuleInfo(projectPath: sub.path, directory: sub.directory, frameworkVersion: framework,
                                    bootVersion: boot, features: features, sourceRoots: roots, resourceRoots: resources,
                                    classpathJars: main.compileClasspathJars + main.runtimeClasspathJars, outputDirs: main.outputDirs,
                                    dependencyPaths: dependencyPaths, isSpring: true)
    }
}
