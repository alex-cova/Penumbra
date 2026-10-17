import Foundation

/// Reads a `pom.xml` into a ``MavenPOM``. External entities stay off, the same rule as
/// ``JaCoCoXMLReportParser``: a `<!DOCTYPE>` never fetches anything.
public enum MavenPOMParser {
    public static func parse(data: Data, file: URL) throws -> MavenPOM {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let builder = TreeBuilder()
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            let line = parser.lineNumber
            throw MavenReadError(
                file: file,
                line: line > 0 ? line : nil,
                message: parser.parserError?.localizedDescription ?? "The POM is not valid XML."
            )
        }
        let project = root.name == "project" ? root : root.child("project")
        guard let project else {
            throw MavenReadError(file: file, line: root.line, message: "The file is not a Maven POM.")
        }
        return interpret(project, file: file)
    }

    public static func parse(contentsOf file: URL) throws -> MavenPOM {
        let data: Data
        do {
            data = try Data(contentsOf: file, options: .mappedIfSafe)
        } catch {
            throw MavenReadError(file: file, message: "The POM could not be read.")
        }
        return try parse(data: data, file: file)
    }

    static func interpret(_ project: MavenXMLElement, file: URL) -> MavenPOM {
        var pom = MavenPOM(file: file, line: project.line)
        if let parent = project.child("parent") {
            pom.parent = MavenGAV(
                groupId: text(parent, "groupId"),
                artifactId: text(parent, "artifactId"),
                version: text(parent, "version")
            )
            if parent.child("relativePath") != nil {
                pom.parentRelativePath = text(parent, "relativePath")
            }
        }
        pom.gav = MavenGAV(
            groupId: text(project, "groupId"),
            artifactId: text(project, "artifactId"),
            version: text(project, "version")
        )
        pom.packaging = text(project, "packaging")
        pom.properties = properties(in: project.child("properties"))
        pom.modules = moduleNames(in: project)
        pom.dependencies = dependencies(in: project.child("dependencies"))
        pom.dependencyManagement = dependencies(in: project.child("dependencyManagement")?.child("dependencies"))
        pom.repositories = repositories(in: project.child("repositories"))
        if let build = project.child("build") {
            pom.directory = text(build, "directory")
            pom.sourceDirectory = text(build, "sourceDirectory")
            pom.testSourceDirectory = text(build, "testSourceDirectory")
            pom.outputDirectory = text(build, "outputDirectory")
            pom.testOutputDirectory = text(build, "testOutputDirectory")
            pom.plugins = plugins(in: build.child("plugins"))
            pom.pluginManagement = plugins(in: build.child("pluginManagement")?.child("plugins"))
        }
        pom.profiles = project.child("profiles")?.children(named: "profile").map(profile) ?? []
        return pom
    }

    private static func text(_ element: MavenXMLElement, _ name: String) -> String {
        element.child(name)?.trimmedText ?? ""
    }

    private static func properties(in element: MavenXMLElement?) -> [String: String] {
        guard let element else { return [:] }
        var result: [String: String] = [:]
        for child in element.children where child.children.isEmpty {
            let value = child.trimmedText
            if !child.name.isEmpty { result[child.name] = value }
        }
        return result
    }

    private static func moduleNames(in project: MavenXMLElement) -> [String] {
        let classic = project.child("modules")?.values(named: "module") ?? []
        let maven4 = project.child("subprojects")?.values(named: "subproject") ?? []
        return classic + maven4
    }

    private static func dependencies(in element: MavenXMLElement?) -> [MavenDependency] {
        guard let element else { return [] }
        return element.children(named: "dependency").map(dependency)
    }

    private static func dependency(_ element: MavenXMLElement) -> MavenDependency {
        let exclusions = element.child("exclusions")?.children(named: "exclusion").map {
            MavenExclusion(groupId: text($0, "groupId"), artifactId: text($0, "artifactId"))
        } ?? []
        let optional = text(element, "optional") == "true"
        return MavenDependency(
            groupId: text(element, "groupId"),
            artifactId: text(element, "artifactId"),
            version: text(element, "version"),
            type: text(element, "type").isEmpty ? "jar" : text(element, "type"),
            classifier: text(element, "classifier"),
            scope: text(element, "scope").isEmpty ? "compile" : text(element, "scope"),
            optional: optional,
            systemPath: text(element, "systemPath"),
            exclusions: exclusions
        )
    }

    private static func repositories(in element: MavenXMLElement?) -> [MavenRepository] {
        guard let element else { return [] }
        return element.children(named: "repository").map { repo in
            let releases = enabled(repo.child("releases"))
            let snapshots = enabled(repo.child("snapshots"))
            return MavenRepository(
                id: text(repo, "id"),
                url: text(repo, "url"),
                releases: releases,
                snapshots: snapshots
            )
        }
    }

    private static func enabled(_ element: MavenXMLElement?) -> Bool {
        guard let element else { return true }
        let flag = text(element, "enabled")
        return flag.isEmpty || flag == "true"
    }

    private static func plugins(in element: MavenXMLElement?) -> [MavenPlugin] {
        guard let element else { return [] }
        return element.children(named: "plugin").map(plugin)
    }

    private static func plugin(_ element: MavenXMLElement) -> MavenPlugin {
        var goals: [String] = []
        var configurationChildren = element.child("configuration")?.children ?? []
        for execution in element.child("executions")?.children(named: "execution") ?? [] {
            goals += execution.child("goals")?.values(named: "goal") ?? []
            configurationChildren += execution.child("configuration")?.children ?? []
        }
        let group = text(element, "groupId")
        let configuration = configurationChildren.isEmpty
            ? nil
            : MavenXMLElement(name: "configuration", children: configurationChildren, line: element.line)
        return MavenPlugin(
            groupId: group.isEmpty ? "org.apache.maven.plugins" : group,
            artifactId: text(element, "artifactId"),
            version: text(element, "version"),
            goals: goals,
            configuration: configuration
        )
    }

    private static func profile(_ element: MavenXMLElement) -> MavenProfile {
        var activation = MavenProfileActivation()
        if let node = element.child("activation") {
            activation.activeByDefault = text(node, "activeByDefault") == "true"
            activation.jdk = text(node, "jdk")
            if let property = node.child("property") {
                activation.propertyName = text(property, "name")
                if property.child("value") != nil {
                    activation.propertyValue = text(property, "value")
                }
            }
            if let os = node.child("os") {
                activation.osFamily = text(os, "family")
                activation.osName = text(os, "name")
            }
            if let file = node.child("file") {
                activation.fileExists = text(file, "exists")
                activation.fileMissing = text(file, "missing")
            }
        }
        var plugins: [MavenPlugin] = []
        if let build = element.child("build") {
            plugins = self.plugins(in: build.child("plugins"))
        }
        return MavenProfile(
            id: text(element, "id"),
            activation: activation,
            properties: properties(in: element.child("properties")),
            modules: moduleNames(in: element),
            dependencies: dependencies(in: element.child("dependencies")),
            dependencyManagement: dependencies(in: element.child("dependencyManagement")?.child("dependencies")),
            repositories: repositories(in: element.child("repositories")),
            plugins: plugins
        )
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: MavenXMLElement?
    private var stack: [MavenXMLElement] = []
    private var text = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        flushText()
        stack.append(MavenXMLElement(name: elementName, line: parser.lineNumber))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?
    ) {
        flushText()
        guard !stack.isEmpty else { return }
        let finished = stack.removeLast()
        if stack.isEmpty {
            root = finished
        } else {
            stack[stack.count - 1].children.append(finished)
        }
    }

    private func flushText() {
        guard !stack.isEmpty, !text.isEmpty else {
            text = ""
            return
        }
        stack[stack.count - 1].text += text
        text = ""
    }
}
