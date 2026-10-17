import Foundation

/// Fetches artifacts that are not in the local repository by running Maven once, on a temporary
/// POM. That POM lists each missing artifact with `*:*` exclusions and copies the project's
/// repositories. It declares no plugins. The process cwd is the temporary folder, with only the
/// wrapper files copied across, so the project's `.mvn/extensions.xml` is not loaded.
public enum MavenDependencyDownload {
    /// The dependencies a download should ask Maven for. Sources requests the `sources` classifier
    /// of every non-project jar. Otherwise the list is the model's missing artifacts, including
    /// parents and BOMs (`type` `pom`).
    public static func artifacts(in model: MavenProjectModel, sources: Bool) -> [MavenDependency] {
        var result: [MavenDependency] = []
        var seen = Set<String>()
        func add(_ dependency: MavenDependency) {
            guard !dependency.groupId.isEmpty, !dependency.artifactId.isEmpty, !dependency.version.isEmpty else { return }
            guard dependency.scope != "system" else { return }
            let key = dependency.mediationKey + ":" + dependency.version
            guard seen.insert(key).inserted else { return }
            result.append(dependency)
        }
        if sources {
            for module in model.modules {
                func walk(_ nodes: [MavenDependencyNode]) {
                    for node in nodes where !node.omitted {
                        if node.projectPath == nil, node.type != "pom", node.scope != "system" {
                            add(MavenDependency(
                                groupId: node.groupId, artifactId: node.artifactId, version: node.version,
                                type: "jar", classifier: "sources"
                            ))
                        }
                        walk(node.children)
                    }
                }
                walk(module.dependencyTree)
            }
        } else {
            for dependency in model.missing { add(dependency) }
        }
        return result
    }

    /// A POM whose only job is `dependency:resolve`.
    public static func document(dependencies: [MavenDependency], repositories: [MavenRepository]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <project>
          <modelVersion>4.0.0</modelVersion>
          <groupId>umbra.maven</groupId>
          <artifactId>download</artifactId>
          <version>1</version>

        """
        if !repositories.isEmpty {
            xml += "  <repositories>\n"
            var seen = Set<String>()
            for repository in repositories where !repository.url.isEmpty {
                let key = repository.id.isEmpty ? repository.url : repository.id
                guard seen.insert(key).inserted else { continue }
                xml += """
                    <repository>
                      <id>\(escape(key))</id>
                      <url>\(escape(repository.url))</url>
                      <releases><enabled>\(repository.releases)</enabled></releases>
                      <snapshots><enabled>\(repository.snapshots)</enabled></snapshots>
                    </repository>

                """
            }
            xml += "  </repositories>\n"
        }
        xml += "  <dependencies>\n"
        for dependency in dependencies {
            xml += "    <dependency>\n"
            xml += "      <groupId>\(escape(dependency.groupId))</groupId>\n"
            xml += "      <artifactId>\(escape(dependency.artifactId))</artifactId>\n"
            xml += "      <version>\(escape(dependency.version))</version>\n"
            let type = dependency.type.isEmpty ? "jar" : dependency.type
            if type != "jar" { xml += "      <type>\(escape(type))</type>\n" }
            if !dependency.classifier.isEmpty {
                xml += "      <classifier>\(escape(dependency.classifier))</classifier>\n"
            }
            xml += """
                  <exclusions>
                    <exclusion>
                      <groupId>*</groupId>
                      <artifactId>*</artifactId>
                    </exclusion>
                  </exclusions>
                </dependency>

            """
        }
        xml += "  </dependencies>\n</project>\n"
        return xml
    }

    /// Writes the POM and runs `dependency:resolve`. An empty list does not start Maven.
    /// The caller checks trust by going through `runner`, and reads the project again afterwards.
    public static func resolve(
        model: MavenProjectModel,
        projectRoot: URL,
        sources: Bool,
        runner: MavenCommandRunner,
        javaHome: URL? = nil,
        executableOverride: String? = nil,
        settingsFile: URL? = nil,
        offline: Bool = false,
        timeout: Duration = .seconds(120),
        output: GradleOutputHandler? = nil
    ) async throws -> GradleCommandResult {
        let dependencies = artifacts(in: model, sources: sources)
        guard !dependencies.isEmpty else {
            return GradleCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-maven-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try copyWrapper(from: projectRoot, to: temp)
        let pom = temp.appendingPathComponent("pom.xml")
        try document(dependencies: dependencies, repositories: model.repositories)
            .write(to: pom, atomically: true, encoding: .utf8)
        return try await runner.run(
            projectDirectory: projectRoot,
            workingDirectory: temp,
            goals: ["dependency:resolve"],
            file: pom,
            javaHome: javaHome,
            executableOverride: executableOverride,
            settingsFile: settingsFile,
            offline: offline,
            timeout: timeout,
            output: output
        )
    }

    /// Copies `.mvn/wrapper` so `mvnw` can start, and leaves `extensions.xml` behind.
    private static func copyWrapper(from projectRoot: URL, to temp: URL) throws {
        let wrapper = projectRoot.appendingPathComponent(".mvn/wrapper")
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: wrapper.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        let destination = temp.appendingPathComponent(".mvn/wrapper", isDirectory: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: wrapper, to: destination)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
