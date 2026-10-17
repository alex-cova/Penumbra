import Foundation

/// What ``MavenProjectReader`` asks for while it builds a model. Profiles the user ticked are added
/// to the ones named in `.mvn/maven.config`.
public struct MavenReadOptions: Sendable {
    public var activeProfiles: [String]
    /// Profiles the user turned off. These stay inactive even when the POM marks them `activeByDefault`
    /// or a JDK range would turn them on. Names in ``activeProfiles`` that are also listed here stay off.
    public var disabledProfiles: [String]
    public var jdkFeatureVersion: Int?
    public var userHome: URL?
    public var environment: [String: String]

    public init(
        activeProfiles: [String] = [],
        disabledProfiles: [String] = [],
        jdkFeatureVersion: Int? = nil,
        userHome: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.activeProfiles = activeProfiles
        self.disabledProfiles = disabledProfiles
        self.jdkFeatureVersion = jdkFeatureVersion
        self.userHome = userHome
        self.environment = environment
    }
}

/// One module after inheritance, profile activation, interpolation and BOM import.
struct MavenEffectiveModule: Sendable {
    var path: String
    var directory: URL
    var pomFile: URL
    var gav: MavenGAV
    var packaging: String
    var properties: [String: String]
    var dependencies: [MavenDependency]
    var dependencyManagement: [MavenDependency]
    var repositories: [MavenRepository]
    var sourceDirectories: [URL]
    var testSourceDirectories: [URL]
    var outputDirectory: URL
    var testOutputDirectory: URL
    var generatedSourceDirectories: [URL]
    var annotationProcessors: [MavenDependency]
    var languageLevel: Int?
    var modules: [String]
    var plugins: [MavenPlugin]
    var profiles: [(id: String, active: Bool)]
    var usesJacocoPrepareAgent: Bool
    var surefireArgLine: String?
    var isAggregator: Bool
    /// Parents and imported BOMs that are not in the local repository yet.
    var missingPOMs: [MavenDependency]
}

/// Builds effective POMs: the parent chain, profile activation, interpolation and imported BOMs.
enum MavenModelBuilder {
    static func module(
        pomFile: URL,
        projectRoot: URL,
        modulePath: String,
        repository: URL,
        options: MavenReadOptions,
        config: MavenConfigFile,
        store: MavenPOMStore
    ) throws -> MavenEffectiveModule {
        let raw = try store.pom(at: pomFile)
        let inherited = try inherit(
            raw, directory: pomFile.deletingLastPathComponent(), repository: repository,
            options: options, config: config, store: store, seen: []
        )
        let activated = activateProfiles(inherited, directory: pomFile.deletingLastPathComponent(), options: options, config: config)
        let interpolated = interpolate(
            activated, directory: pomFile.deletingLastPathComponent(), projectRoot: projectRoot, options: options, config: config
        )
        let withBOMs = try importBOMs(interpolated, repository: repository, store: store, seen: [])
        return makeModule(withBOMs, pomFile: pomFile, projectRoot: projectRoot, modulePath: modulePath)
    }

    // MARK: Inheritance

    private struct Inherited {
        var pomFile: URL
        var directory: URL
        var gav: MavenGAV
        var parentGAV: MavenGAV?
        var packaging: String
        var properties: [String: String]
        var modules: [String]
        var dependencies: [MavenDependency]
        var dependencyManagement: [MavenDependency]
        var repositories: [MavenRepository]
        var directoryName: String
        var sourceDirectory: String
        var testSourceDirectory: String
        var outputDirectory: String
        var testOutputDirectory: String
        var plugins: [MavenPlugin]
        var profiles: [MavenProfile]
        var activeProfileIDs: Set<String>
        var missingPOMs: [MavenDependency] = []
    }

    private static func inherit(
        _ pom: MavenPOM,
        directory: URL,
        repository: URL,
        options: MavenReadOptions,
        config: MavenConfigFile,
        store: MavenPOMStore,
        seen: Set<String>
    ) throws -> Inherited {
        var parent: Inherited?
        var missingParent: MavenDependency?
        if let declared = pom.parent {
            let key = "\(declared.groupId):\(declared.artifactId):\(declared.version):\(pom.file.path)"
            if !seen.contains(key) {
                if let parentPOM = try resolveParent(
                    declared, relativePath: pom.parentRelativePath, directory: directory, repository: repository,
                    config: config, pomProperties: pom.properties, store: store
                ) {
                    parent = try inherit(
                        parentPOM, directory: parentPOM.file.deletingLastPathComponent(), repository: repository,
                        options: options, config: config, store: store, seen: seen.union([key])
                    )
                } else {
                    missingParent = missingParentDependency(
                        declared, relativePath: pom.parentRelativePath, directory: directory, repository: repository,
                        config: config, pomProperties: pom.properties
                    )
                }
            }
        }
        var result = Inherited(
            pomFile: pom.file,
            directory: directory,
            gav: MavenGAV(
                groupId: firstNonEmpty(pom.gav.groupId, parent?.gav.groupId),
                artifactId: pom.gav.artifactId,
                version: firstNonEmpty(pom.gav.version, parent?.gav.version)
            ),
            parentGAV: parent?.gav ?? pom.parent,
            packaging: firstNonEmpty(pom.packaging, "jar"),
            properties: merging(parent?.properties ?? [:], pom.properties),
            modules: pom.modules,
            dependencies: (parent?.dependencies ?? []) + pom.dependencies,
            dependencyManagement: mergeManagement(parent?.dependencyManagement ?? [], pom.dependencyManagement),
            repositories: mergeRepositories(parent?.repositories ?? [], pom.repositories),
            directoryName: firstNonEmpty(pom.directory, parent?.directoryName, "target"),
            sourceDirectory: firstNonEmpty(pom.sourceDirectory, parent?.sourceDirectory, "src/main/java"),
            testSourceDirectory: firstNonEmpty(pom.testSourceDirectory, parent?.testSourceDirectory, "src/test/java"),
            outputDirectory: firstNonEmpty(pom.outputDirectory, parent?.outputDirectory, "target/classes"),
            testOutputDirectory: firstNonEmpty(pom.testOutputDirectory, parent?.testOutputDirectory, "target/test-classes"),
            plugins: mergePlugins(parent?.plugins ?? [], pom.plugins, management: pom.pluginManagement),
            profiles: mergeProfiles(parent?.profiles ?? [], pom.profiles),
            activeProfileIDs: [],
            missingPOMs: parent?.missingPOMs ?? []
        )
        if let missingParent { result.missingPOMs.append(missingParent) }
        if result.gav.groupId.isEmpty, let parentGAV = result.parentGAV {
            result.gav.groupId = parentGAV.groupId
        }
        if result.gav.version.isEmpty, let parentGAV = result.parentGAV {
            result.gav.version = parentGAV.version
        }
        return result
    }

    private static func resolveParent(
        _ gav: MavenGAV,
        relativePath: String?,
        directory: URL,
        repository: URL,
        config: MavenConfigFile,
        pomProperties: [String: String],
        store: MavenPOMStore
    ) throws -> MavenPOM? {
        let relative = relativePath ?? "../pom.xml"
        if !relative.isEmpty {
            let file = directory.appendingPathComponent(relative).standardizedFileURL
            if FileManager.default.fileExists(atPath: file.path) {
                return try store.pom(at: file)
            }
        }
        let early = earlyProperties(pomProperties, config: config, directory: directory)
        let resolved = MavenGAV(
            groupId: interpolateScalar(gav.groupId, properties: early),
            artifactId: interpolateScalar(gav.artifactId, properties: early),
            version: interpolateScalar(gav.version, properties: early)
        )
        guard resolved.isComplete else { return nil }
        guard let url = MavenLocalRepository.artifactURL(
            groupId: resolved.groupId, artifactId: resolved.artifactId, version: resolved.version,
            extension: "pom", repository: repository
        ) else { return nil }
        return try store.pom(at: url)
    }

    /// A parent GAV that is fully known and present neither beside the POM nor in the local repository.
    private static func missingParentDependency(
        _ gav: MavenGAV,
        relativePath: String?,
        directory: URL,
        repository: URL,
        config: MavenConfigFile,
        pomProperties: [String: String]
    ) -> MavenDependency? {
        let early = earlyProperties(pomProperties, config: config, directory: directory)
        let resolved = MavenGAV(
            groupId: interpolateScalar(gav.groupId, properties: early),
            artifactId: interpolateScalar(gav.artifactId, properties: early),
            version: interpolateScalar(gav.version, properties: early)
        )
        guard resolved.isComplete else { return nil }
        return MavenDependency(
            groupId: resolved.groupId, artifactId: resolved.artifactId, version: resolved.version, type: "pom"
        )
    }

    // MARK: Profiles

    private static func activateProfiles(
        _ model: Inherited, directory: URL, options: MavenReadOptions, config: MavenConfigFile
    ) -> Inherited {
        var requested = Set(config.profiles + options.activeProfiles)
        let disabled = Set(config.disabledProfiles + options.disabledProfiles)
        requested.subtract(disabled)
        let properties = model.properties.merging(config.properties) { _, new in new }
        var explicit = false
        var selected: [MavenProfile] = []
        for profile in model.profiles where !disabled.contains(profile.id) {
            if requested.contains(profile.id) || isActive(profile.activation, properties: properties, directory: directory, jdk: options.jdkFeatureVersion) {
                selected.append(profile)
                explicit = true
            }
        }
        if !explicit {
            selected = model.profiles.filter { $0.activation.activeByDefault && !disabled.contains($0.id) }
        }
        var result = model
        for profile in selected {
            result.properties = merging(result.properties, profile.properties)
            result.modules += profile.modules
            result.dependencies += profile.dependencies
            result.dependencyManagement = mergeManagement(result.dependencyManagement, profile.dependencyManagement)
            result.repositories = mergeRepositories(result.repositories, profile.repositories)
            result.plugins = mergePlugins(result.plugins, profile.plugins, management: [])
        }
        result.activeProfileIDs = Set(selected.map(\.id))
        return result
    }

    static func isActive(
        _ activation: MavenProfileActivation,
        properties: [String: String],
        directory: URL,
        jdk: Int?
    ) -> Bool {
        if activation.isEmpty { return false }
        if activation.activeByDefault && activation.jdk.isEmpty && activation.propertyName.isEmpty
            && activation.osFamily.isEmpty && activation.osName.isEmpty
            && activation.fileExists.isEmpty && activation.fileMissing.isEmpty {
            return false
        }
        if !activation.jdk.isEmpty {
            guard let jdk, jdkMatches(activation.jdk, feature: jdk) else { return false }
        }
        if !activation.propertyName.isEmpty {
            let name = activation.propertyName
            if name.hasPrefix("!") {
                if properties[String(name.dropFirst())] != nil { return false }
            } else if let expected = activation.propertyValue {
                if properties[name] != expected { return false }
            } else if properties[name] == nil {
                return false
            }
        }
        if !activation.osFamily.isEmpty || !activation.osName.isEmpty {
            guard osMatches(family: activation.osFamily, name: activation.osName) else { return false }
        }
        let fileManager = FileManager.default
        if !activation.fileExists.isEmpty {
            let url = directory.appendingPathComponent(activation.fileExists)
            if !fileManager.fileExists(atPath: url.path) { return false }
        }
        if !activation.fileMissing.isEmpty {
            let url = directory.appendingPathComponent(activation.fileMissing)
            if fileManager.fileExists(atPath: url.path) { return false }
        }
        return !activation.jdk.isEmpty || !activation.propertyName.isEmpty || !activation.osFamily.isEmpty
            || !activation.osName.isEmpty || !activation.fileExists.isEmpty || !activation.fileMissing.isEmpty
    }

    static func jdkMatches(_ range: String, feature: Int) -> Bool {
        let text = range.trimmingCharacters(in: .whitespaces)
        if let exact = Int(text) { return feature == exact }
        if text == "1.8" { return feature == 8 }
        if text.contains("[") || text.contains("(") {
            return MavenVersion.satisfies(String(feature), range: text.replacingOccurrences(of: "1.8", with: "8"))
        }
        return text == String(feature)
    }

    private static func osMatches(family: String, name: String) -> Bool {
        #if os(macOS)
        let familyMatch = family.isEmpty || family.caseInsensitiveCompare("mac") == .orderedSame
            || family.caseInsensitiveCompare("unix") == .orderedSame
        let lowered = name.lowercased()
        let nameMatch = name.isEmpty || lowered.contains("mac") || lowered.contains("darwin")
        return familyMatch && nameMatch
        #else
        return false
        #endif
    }

    // MARK: Interpolation

    private static func interpolate(
        _ model: Inherited, directory: URL, projectRoot: URL, options: MavenReadOptions, config: MavenConfigFile
    ) -> Inherited {
        var properties = model.properties
        properties["project.groupId"] = model.gav.groupId
        properties["project.artifactId"] = model.gav.artifactId
        properties["project.version"] = model.gav.version
        properties["project.packaging"] = model.packaging
        properties["pom.groupId"] = model.gav.groupId
        properties["pom.artifactId"] = model.gav.artifactId
        properties["pom.version"] = model.gav.version
        if let parent = model.parentGAV {
            properties["parent.groupId"] = parent.groupId
            properties["parent.artifactId"] = parent.artifactId
            properties["parent.version"] = parent.version
            properties["project.parent.groupId"] = parent.groupId
            properties["project.parent.artifactId"] = parent.artifactId
            properties["project.parent.version"] = parent.version
        }
        properties["basedir"] = directory.path
        properties["project.basedir"] = directory.path
        properties["project.baseUri"] = directory.absoluteURL.absoluteString
        properties["maven.multiModuleProjectDirectory"] = projectRoot.path
        let home = (options.userHome ?? FileManager.default.homeDirectoryForCurrentUser).path
        properties["user.home"] = home
        if let feature = options.jdkFeatureVersion {
            properties["java.version"] = String(feature)
            properties["java.specification.version"] = String(feature)
        }
        for (key, value) in config.properties { properties[key] = value }
        for (key, value) in options.environment {
            properties["env.\(key)"] = value
        }
        properties = expandProperties(properties)
        var result = model
        result.gav.groupId = interpolateScalar(result.gav.groupId, properties: properties)
        result.gav.artifactId = interpolateScalar(result.gav.artifactId, properties: properties)
        result.gav.version = interpolateScalar(result.gav.version, properties: properties)
        properties["project.version"] = result.gav.version
        properties["pom.version"] = result.gav.version
        properties = expandProperties(properties)
        result.properties = properties
        result.dependencies = result.dependencies.map { interpolate($0, properties: properties) }
        result.dependencyManagement = result.dependencyManagement.map { interpolate($0, properties: properties) }
        result.modules = result.modules.map { interpolateScalar($0, properties: properties) }
        result.directoryName = interpolateScalar(result.directoryName, properties: properties)
        result.sourceDirectory = interpolateScalar(result.sourceDirectory, properties: properties)
        result.testSourceDirectory = interpolateScalar(result.testSourceDirectory, properties: properties)
        result.outputDirectory = interpolateScalar(result.outputDirectory, properties: properties)
        result.testOutputDirectory = interpolateScalar(result.testOutputDirectory, properties: properties)
        result.plugins = result.plugins.map { plugin in
            var copy = plugin
            copy.version = interpolateScalar(plugin.version, properties: properties)
            return copy
        }
        return result
    }

    private static func earlyProperties(
        _ pomProperties: [String: String], config: MavenConfigFile, directory: URL
    ) -> [String: String] {
        var properties = pomProperties
        properties["basedir"] = directory.path
        properties["project.basedir"] = directory.path
        for (key, value) in config.properties { properties[key] = value }
        return expandProperties(properties)
    }

    private static func expandProperties(_ properties: [String: String]) -> [String: String] {
        var current = properties
        for _ in 0..<16 {
            var changed = false
            for (key, value) in current {
                let expanded = interpolateScalar(value, properties: current)
                if expanded != value {
                    current[key] = expanded
                    changed = true
                }
            }
            if !changed { break }
        }
        return current
    }

    static func interpolateScalar(_ value: String, properties: [String: String]) -> String {
        guard value.contains("${") else { return value }
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "$", value.index(after: index) < value.endIndex, value[value.index(after: index)] == "{" {
                let start = value.index(index, offsetBy: 2)
                if let end = value[start...].firstIndex(of: "}") {
                    let key = String(value[start..<end])
                    result += properties[key] ?? "${\(key)}"
                    index = value.index(after: end)
                    continue
                }
            }
            result.append(value[index])
            index = value.index(after: index)
        }
        return result
    }

    private static func interpolate(_ dependency: MavenDependency, properties: [String: String]) -> MavenDependency {
        var copy = dependency
        copy.groupId = interpolateScalar(dependency.groupId, properties: properties)
        copy.artifactId = interpolateScalar(dependency.artifactId, properties: properties)
        copy.version = interpolateScalar(dependency.version, properties: properties)
        copy.systemPath = interpolateScalar(dependency.systemPath, properties: properties)
        copy.classifier = interpolateScalar(dependency.classifier, properties: properties)
        return copy
    }

    // MARK: BOMs

    private static func importBOMs(
        _ model: Inherited, repository: URL, store: MavenPOMStore, seen: Set<String>
    ) throws -> Inherited {
        var result = model
        var seen = seen
        var pending = result.dependencyManagement.filter { $0.scope == "import" && ($0.type == "pom" || $0.resolvedType == "pom") }
        var managed = result.dependencyManagement.filter { $0.scope != "import" }
        while !pending.isEmpty {
            let entry = pending.removeFirst()
            let key = "\(entry.groupId):\(entry.artifactId):\(entry.version)"
            guard seen.insert(key).inserted else { continue }
            guard let url = MavenLocalRepository.artifactURL(
                groupId: entry.groupId, artifactId: entry.artifactId, version: entry.version,
                extension: "pom", repository: repository
            ) else {
                result.missingPOMs.append(MavenDependency(
                    groupId: entry.groupId, artifactId: entry.artifactId, version: entry.version,
                    type: "pom", scope: "import"
                ))
                continue
            }
            let bom = try store.pom(at: url)
            let imported = bom.dependencyManagement.map { interpolate($0, properties: result.properties) }
            for item in imported where item.scope == "import" && item.type == "pom" {
                pending.append(item)
            }
            let concrete = imported.filter { $0.scope != "import" }
            managed = mergeManagement(concrete, managed)
        }
        result.dependencyManagement = managed
        return result
    }

    // MARK: Module

    private static func makeModule(
        _ model: Inherited, pomFile: URL, projectRoot: URL, modulePath: String
    ) -> MavenEffectiveModule {
        let directory = pomFile.deletingLastPathComponent()
        let sources = sourceList(model.sourceDirectory, base: directory)
        let tests = sourceList(model.testSourceDirectory, base: directory)
        let (extraMain, extraTest) = buildHelperSources(plugins: model.plugins, base: directory)
        let output = resolvePath(model.outputDirectory, base: directory)
        let testOutput = resolvePath(model.testOutputDirectory, base: directory)
        let generated = generatedSources(base: directory)
        let compiler = model.plugins.first { $0.artifactId == "maven-compiler-plugin" }
        let processors = annotationProcessors(in: compiler?.configuration)
        let level = languageLevel(properties: model.properties, compiler: compiler?.configuration)
        let surefire = model.plugins.first { $0.artifactId == "maven-surefire-plugin" }
        let argLine = surefire?.configuration?.child("argLine")?.trimmedText
        let jacoco = model.plugins.contains { plugin in
            plugin.artifactId == "jacoco-maven-plugin" && plugin.goals.contains("prepare-agent")
        }
        let active = model.activeProfileIDs
        return MavenEffectiveModule(
            path: modulePath,
            directory: directory,
            pomFile: pomFile,
            gav: model.gav,
            packaging: model.packaging,
            properties: model.properties,
            dependencies: model.dependencies.filter { $0.scope != "import" },
            dependencyManagement: model.dependencyManagement,
            repositories: model.repositories,
            sourceDirectories: sources + extraMain,
            testSourceDirectories: tests + extraTest,
            outputDirectory: output,
            testOutputDirectory: testOutput,
            generatedSourceDirectories: generated,
            annotationProcessors: processors,
            languageLevel: level,
            modules: model.modules,
            plugins: model.plugins,
            profiles: model.profiles.map { ($0.id, active.contains($0.id)) },
            usesJacocoPrepareAgent: jacoco,
            surefireArgLine: argLine.flatMap { $0.isEmpty ? nil : $0 },
            isAggregator: model.packaging == "pom" || !model.modules.isEmpty,
            missingPOMs: model.missingPOMs
        )
    }

    static func languageLevel(properties: [String: String], compiler: MavenXMLElement?) -> Int? {
        let candidates = [
            properties["maven.compiler.release"],
            compiler?.child("release")?.trimmedText,
            properties["maven.compiler.source"],
            compiler?.child("source")?.trimmedText
        ]
        for candidate in candidates {
            guard let candidate, !candidate.isEmpty else { continue }
            if let level = parseLevel(candidate) { return level }
        }
        return nil
    }

    static func parseLevel(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "1.8" || trimmed.hasPrefix("1.8") { return 8 }
        if trimmed.hasPrefix("1."), let minor = Int(trimmed.dropFirst(2).prefix(while: \.isNumber)) { return minor }
        let digits = trimmed.prefix(while: \.isNumber)
        return Int(digits)
    }

    private static func annotationProcessors(in configuration: MavenXMLElement?) -> [MavenDependency] {
        guard let paths = configuration?.child("annotationProcessorPaths") else { return [] }
        return paths.children(named: "path").map { path in
            MavenDependency(
                groupId: path.child("groupId")?.trimmedText ?? "",
                artifactId: path.child("artifactId")?.trimmedText ?? "",
                version: path.child("version")?.trimmedText ?? "",
                type: "jar"
            )
        }.filter { !$0.groupId.isEmpty && !$0.artifactId.isEmpty }
    }

    private static func buildHelperSources(plugins: [MavenPlugin], base: URL) -> ([URL], [URL]) {
        var main: [URL] = []
        var test: [URL] = []
        for plugin in plugins where plugin.artifactId == "build-helper-maven-plugin" {
            let sources = plugin.configuration?.child("sources")?.values(named: "source") ?? []
            if plugin.goals.contains("add-test-source"), !plugin.goals.contains("add-source") {
                test += sources.map { resolvePath($0, base: base) }
            } else if plugin.goals.contains("add-source") {
                main += sources.map { resolvePath($0, base: base) }
            }
        }
        return (main, test)
    }

    private static func generatedSources(base: URL) -> [URL] {
        let root = base.appendingPathComponent("target/generated-sources", isDirectory: true)
        var result = [root.appendingPathComponent("annotations", isDirectory: true)]
        if let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) {
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                if child.lastPathComponent != "annotations" { result.append(child) }
            }
        }
        return result
    }

    private static func sourceList(_ path: String, base: URL) -> [URL] {
        path.isEmpty ? [] : [resolvePath(path, base: base)]
    }

    static func resolvePath(_ path: String, base: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        return base.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }

    // MARK: Merge

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            if let value, !value.isEmpty { return value }
        }
        return ""
    }

    private static func merging(_ base: [String: String], _ overlay: [String: String]) -> [String: String] {
        base.merging(overlay) { _, new in new }
    }

    private static func mergeProfiles(_ base: [MavenProfile], _ overlay: [MavenProfile]) -> [MavenProfile] {
        var result: [MavenProfile] = []
        var index: [String: Int] = [:]
        for profile in base + overlay {
            if let existing = index[profile.id] {
                result[existing] = profile
            } else {
                index[profile.id] = result.count
                result.append(profile)
            }
        }
        return result
    }

    private static func mergeManagement(_ base: [MavenDependency], _ overlay: [MavenDependency]) -> [MavenDependency] {
        var byKey: [String: MavenDependency] = [:]
        var order: [String] = []
        for entry in base + overlay {
            let key = entry.mediationKey
            if byKey[key] == nil { order.append(key) }
            byKey[key] = entry
        }
        return order.compactMap { byKey[$0] }
    }

    private static func mergeRepositories(_ base: [MavenRepository], _ overlay: [MavenRepository]) -> [MavenRepository] {
        var seen = Set<String>()
        var result: [MavenRepository] = []
        for repository in overlay + base {
            let key = repository.id.isEmpty ? repository.url : repository.id
            if seen.insert(key).inserted { result.append(repository) }
        }
        return result
    }

    private static func mergePlugins(_ base: [MavenPlugin], _ overlay: [MavenPlugin], management: [MavenPlugin]) -> [MavenPlugin] {
        var byKey: [String: MavenPlugin] = [:]
        var order: [String] = []
        func add(_ plugin: MavenPlugin) {
            let key = plugin.key
            guard var existing = byKey[key] else {
                order.append(key)
                byKey[key] = plugin
                return
            }
            if !plugin.version.isEmpty { existing.version = plugin.version }
            if plugin.configuration != nil { existing.configuration = plugin.configuration }
            for goal in plugin.goals where !existing.goals.contains(goal) {
                existing.goals.append(goal)
            }
            byKey[key] = existing
        }
        for plugin in management { add(plugin) }
        for plugin in base { add(plugin) }
        for plugin in overlay { add(plugin) }
        return order.compactMap { byKey[$0] }
    }
}
