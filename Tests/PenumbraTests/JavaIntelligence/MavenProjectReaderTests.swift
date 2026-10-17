import XCTest
@testable import JavaIntelligence

final class MavenProjectReaderTests: XCTestCase {
    private var fixture: MavenFixture!

    override func setUp() async throws {
        fixture = try MavenFixture()
    }

    override func tearDown() {
        fixture?.remove()
        fixture = nil
    }

    func testParentInheritanceAndDefaultRelativePath() async throws {
        try fixture.write(
            fixture.project.deletingLastPathComponent().appendingPathComponent("pom.xml"),
            MavenFixture.pom(group: "com.example", artifact: "parent", version: "1.0", body: """
            <dependencyManagement>
              <dependencies>
                <dependency>
                  <groupId>com.example</groupId>
                  <artifactId>lib</artifactId>
                  <version>3</version>
                </dependency>
              </dependencies>
            </dependencyManagement>
            """)
        )
        try fixture.install(group: "com.example", artifact: "lib", version: "3")
        try fixture.writeProject("pom.xml", """
        <project>
          <modelVersion>4.0.0</modelVersion>
          <parent>
            <groupId>com.example</groupId>
            <artifactId>parent</artifactId>
            <version>1.0</version>
          </parent>
          <artifactId>app</artifactId>
          <dependencies>
            <dependency>
              <groupId>com.example</groupId>
              <artifactId>lib</artifactId>
            </dependency>
          </dependencies>
        </project>
        """)
        let model = try await fixture.read()
        let app = try XCTUnwrap(model.modules.first)
        XCTAssertEqual(app.groupId, "com.example")
        XCTAssertEqual(app.version, "1.0")
        XCTAssertEqual(app.compileClasspathJars.map(\.lastPathComponent), ["lib-3.jar"])
    }

    func testExplicitRelativePath() async throws {
        let family = fixture.project.deletingLastPathComponent().appendingPathComponent("family/pom.xml")
        try fixture.write(family, MavenFixture.pom(group: "com.example", artifact: "family", version: "9", body: """
        <properties><maven.compiler.release>17</maven.compiler.release></properties>
        """))
        try fixture.writeProject("pom.xml", """
        <project>
          <modelVersion>4.0.0</modelVersion>
          <parent>
            <groupId>com.example</groupId>
            <artifactId>family</artifactId>
            <version>9</version>
            <relativePath>../family/pom.xml</relativePath>
          </parent>
          <artifactId>app</artifactId>
        </project>
        """)
        let model = try await fixture.read()
        XCTAssertEqual(model.modules.first?.languageLevel, 17)
        XCTAssertEqual(model.modules.first?.version, "9")
    }

    func testBOMImportAndLocalManagementWins() async throws {
        try fixture.install(group: "com.example", artifact: "bom", version: "1", pom: """
        <project>
          <modelVersion>4.0.0</modelVersion>
          <groupId>com.example</groupId>
          <artifactId>bom</artifactId>
          <version>1</version>
          <packaging>pom</packaging>
          <dependencyManagement>
            <dependencies>
              <dependency>
                <groupId>com.example</groupId>
                <artifactId>lib</artifactId>
                <version>2</version>
              </dependency>
              <dependency>
                <groupId>com.example</groupId>
                <artifactId>other</artifactId>
                <version>4</version>
              </dependency>
            </dependencies>
          </dependencyManagement>
        </project>
        """)
        try fixture.install(group: "com.example", artifact: "lib", version: "9")
        try fixture.install(group: "com.example", artifact: "other", version: "4")
        try fixture.writeProject("pom.xml", MavenFixture.pom(group: "com.example", artifact: "app", version: "1", body: """
        <dependencyManagement>
          <dependencies>
            <dependency>
              <groupId>com.example</groupId>
              <artifactId>bom</artifactId>
              <version>1</version>
              <type>pom</type>
              <scope>import</scope>
            </dependency>
            <dependency>
              <groupId>com.example</groupId>
              <artifactId>lib</artifactId>
              <version>9</version>
            </dependency>
          </dependencies>
        </dependencyManagement>
        <dependencies>
          <dependency>
            <groupId>com.example</groupId>
            <artifactId>lib</artifactId>
          </dependency>
          <dependency>
            <groupId>com.example</groupId>
            <artifactId>other</artifactId>
          </dependency>
        </dependencies>
        """))
        let names = try await fixture.read().compileNames(":")
        XCTAssertEqual(names, ["lib-9.jar", "other-4.jar"])
    }

    func testNearestWinsAndFirstDeclaration() async throws {
        try fixture.install(group: "com.example", artifact: "b", version: "1", pom: MavenFixture.pom(
            group: "com.example", artifact: "b", version: "1", body: dependency("d", "1")
        ))
        try fixture.install(group: "com.example", artifact: "c", version: "1", pom: MavenFixture.pom(
            group: "com.example", artifact: "c", version: "1", body: dependency("d", "2")
        ))
        try fixture.install(group: "com.example", artifact: "b", version: "1")
        try fixture.install(group: "com.example", artifact: "c", version: "1")
        try fixture.install(group: "com.example", artifact: "d", version: "1")
        try fixture.install(group: "com.example", artifact: "d", version: "2")
        try fixture.writeProject("pom.xml", MavenFixture.pom(group: "com.example", artifact: "app", version: "1", body: """
        <dependencies>
          \(dependencyElement("b", "1"))
          \(dependencyElement("c", "1"))
        </dependencies>
        """))
        let first = try await fixture.read().compileNames(":")
        XCTAssertTrue(first.contains("d-1.jar"))
        XCTAssertFalse(first.contains("d-2.jar"))

        try fixture.writeProject("pom.xml", MavenFixture.pom(group: "com.example", artifact: "app", version: "1", body: """
        <dependencies>
          \(dependencyElement("d", "2"))
          \(dependencyElement("b", "1"))
          \(dependencyElement("c", "1"))
        </dependencies>
        """))
        fixture.store = MavenPOMStore()
        let nearest = try await fixture.read().compileNames(":")
        XCTAssertTrue(nearest.contains("d-2.jar"))
        XCTAssertFalse(nearest.contains("d-1.jar"))
        let reread = try await fixture.read()
        let tree = try XCTUnwrap(reread.modules.first?.dependencyTree)
        XCTAssertTrue(Self.flatten(tree).contains { $0.artifactId == "d" && $0.version == "1" && $0.omitted })
    }

    func testExclusionsOptionalAndScopes() async throws {
        try fixture.install(group: "com.example", artifact: "b", version: "1", pom: MavenFixture.pom(
            group: "com.example", artifact: "b", version: "1", body: """
            <dependencies>
              \(dependencyElement("d", "1"))
              \(dependencyElement("runtime-lib", "1", scope: "runtime"))
              \(dependencyElement("provided-lib", "1", scope: "provided"))
              \(dependencyElement("optional-lib", "1", optional: true))
            </dependencies>
            """
        ))
        for artifact in ["b", "d", "runtime-lib", "provided-lib", "optional-lib", "direct-optional"] {
            try fixture.install(group: "com.example", artifact: artifact, version: "1")
        }
        try fixture.writeProject("pom.xml", MavenFixture.pom(group: "com.example", artifact: "app", version: "1", body: """
        <dependencies>
          <dependency>
            <groupId>com.example</groupId>
            <artifactId>b</artifactId>
            <version>1</version>
            <exclusions>
              <exclusion><groupId>com.example</groupId><artifactId>d</artifactId></exclusion>
            </exclusions>
          </dependency>
          \(dependencyElement("direct-optional", "1", optional: true))
          \(dependencyElement("provided-lib", "1", scope: "provided"))
          \(dependencyElement("runtime-lib", "1", scope: "runtime"))
        </dependencies>
        """))
        let model = try await fixture.read()
        let module = try XCTUnwrap(model.modules.first)
        XCTAssertFalse(module.compileClasspathJars.map(\.lastPathComponent).contains("d-1.jar"))
        XCTAssertFalse(module.compileClasspathJars.map(\.lastPathComponent).contains("optional-lib-1.jar"))
        XCTAssertTrue(module.compileClasspathJars.map(\.lastPathComponent).contains("direct-optional-1.jar"))
        XCTAssertTrue(module.compileClasspathJars.map(\.lastPathComponent).contains("provided-lib-1.jar"))
        XCTAssertFalse(module.runtimeClasspathJars.map(\.lastPathComponent).contains("provided-lib-1.jar"))
        XCTAssertTrue(module.runtimeClasspathJars.map(\.lastPathComponent).contains("runtime-lib-1.jar"))
        XCTAssertFalse(module.compileClasspathJars.map(\.lastPathComponent).contains("runtime-lib-1.jar"))
        XCTAssertTrue(module.testClasspathJars.map(\.lastPathComponent).contains("provided-lib-1.jar"))
        XCTAssertTrue(module.testClasspathJars.map(\.lastPathComponent).contains("runtime-lib-1.jar"))
    }

    func testWildcardExclusion() async throws {
        try fixture.install(group: "com.example", artifact: "b", version: "1", pom: MavenFixture.pom(
            group: "com.example", artifact: "b", version: "1", body: dependency("d", "1")
        ))
        try fixture.install(group: "com.example", artifact: "b", version: "1")
        try fixture.install(group: "com.example", artifact: "d", version: "1")
        try fixture.writeProject("pom.xml", MavenFixture.pom(group: "com.example", artifact: "app", version: "1", body: """
        <dependencies>
          <dependency>
            <groupId>com.example</groupId>
            <artifactId>b</artifactId>
            <version>1</version>
            <exclusions>
              <exclusion><groupId>*</groupId><artifactId>*</artifactId></exclusion>
            </exclusions>
          </dependency>
        </dependencies>
        """))
        let names = try await fixture.read().compileNames(":")
        XCTAssertEqual(names, ["b-1.jar"])
    }

    func testTestJarIsTheOtherModulesTestSourceSet() async throws {
        try fixture.writeProject("pom.xml", MavenFixture.pom(
            group: "com.example", artifact: "app", version: "1", packaging: "pom", body: """
            <modules><module>api</module></modules>
            <dependencies>
              <dependency>
                <groupId>com.example</groupId>
                <artifactId>api</artifactId>
                <version>1</version>
                <type>test-jar</type>
              </dependency>
            </dependencies>
            """
        ))
        try fixture.writeProject("api/pom.xml", MavenFixture.pom(group: "com.example", artifact: "api", version: "1"))
        let model = try await fixture.read()
        let root = try XCTUnwrap(model.modules.first { $0.path == ":" })
        XCTAssertEqual(root.compileProjectDependencies, [MavenModuleDependency(projectPath: ":api", sourceSetName: "test")])
        XCTAssertTrue(root.compileClasspathJars.isEmpty)
        let projected = model.javaProjectModel
        let main = try XCTUnwrap(projected.subprojects.first { $0.path == ":" }?.sourceSets.first { $0.name == "main" })
        XCTAssertEqual(main.projectDependencies.map(\.sourceSetName), ["test"])
    }

    func testProfileActivationInterpolationAndRevision() async throws {
        try fixture.install(group: "com.example", artifact: "lib", version: "1.2.3")
        try fixture.install(group: "com.example", artifact: "jdk-lib", version: "1")
        try fixture.writeProject(".mvn/maven.config", "-Drevision=1.2.3\n")
        try fixture.writeProject("pom.xml", """
        <project>
          <modelVersion>4.0.0</modelVersion>
          <groupId>com.example</groupId>
          <artifactId>app</artifactId>
          <version>${revision}</version>
          <properties><maven.compiler.release>11</maven.compiler.release></properties>
          <dependencies>
            <dependency>
              <groupId>com.example</groupId>
              <artifactId>lib</artifactId>
              <version>${revision}</version>
            </dependency>
          </dependencies>
          <profiles>
            <profile>
              <id>dev</id>
              <activation><activeByDefault>true</activeByDefault></activation>
              <properties><maven.compiler.release>17</maven.compiler.release></properties>
            </profile>
            <profile>
              <id>extra</id>
              <dependencies>
                \(dependencyElement("jdk-lib", "1"))
              </dependencies>
            </profile>
            <profile>
              <id>modern</id>
              <activation><jdk>[17,)</jdk></activation>
              <properties><maven.compiler.release>21</maven.compiler.release></properties>
            </profile>
          </profiles>
        </project>
        """)
        let quiet = try await fixture.read(jdk: 11)
        XCTAssertEqual(quiet.modules.first?.version, "1.2.3")
        XCTAssertEqual(quiet.modules.first?.languageLevel, 17)
        XCTAssertEqual(quiet.profiles.first { $0.id == "dev" }?.active, true)
        XCTAssertEqual(quiet.profiles.first { $0.id == "extra" }?.active, false)
        XCTAssertEqual(quiet.profiles.first { $0.id == "modern" }?.active, false)
        XCTAssertTrue(quiet.compileNames(":").contains("lib-1.2.3.jar"))
        XCTAssertFalse(quiet.compileNames(":").contains("jdk-lib-1.jar"))

        let modern = try await fixture.read(jdk: 17)
        XCTAssertEqual(modern.modules.first?.languageLevel, 21)
        XCTAssertEqual(modern.profiles.first { $0.id == "dev" }?.active, false)
        XCTAssertEqual(modern.profiles.first { $0.id == "modern" }?.active, true)

        let extra = try await fixture.read(profiles: ["extra"], jdk: 11)
        XCTAssertEqual(extra.profiles.first { $0.id == "extra" }?.active, true)
        XCTAssertEqual(extra.profiles.first { $0.id == "dev" }?.active, false)
        XCTAssertTrue(extra.compileNames(":").contains("jdk-lib-1.jar"))
    }

    func testVersionRangePicksHighestInstalled() async throws {
        try fixture.install(group: "com.example", artifact: "lib", version: "1.0")
        try fixture.install(group: "com.example", artifact: "lib", version: "1.5")
        try fixture.install(group: "com.example", artifact: "lib", version: "2.0")
        try fixture.writeProject("pom.xml", MavenFixture.pom(group: "com.example", artifact: "app", version: "1", body: """
        <dependencies>
          <dependency>
            <groupId>com.example</groupId>
            <artifactId>lib</artifactId>
            <version>[1.0,2.0)</version>
          </dependency>
        </dependencies>
        """))
        let names = try await fixture.read().compileNames(":")
        XCTAssertEqual(names, ["lib-1.5.jar"])
    }

    func testReactorDependencyIsNotAJar() async throws {
        try fixture.writeProject("pom.xml", MavenFixture.pom(
            group: "com.example", artifact: "root", version: "1", packaging: "pom",
            body: "<modules><module>services/api</module><module>services/app</module></modules>"
        ))
        try fixture.writeProject("services/api/pom.xml", MavenFixture.pom(group: "com.example", artifact: "api", version: "1"))
        try fixture.writeProject("services/app/pom.xml", MavenFixture.pom(group: "com.example", artifact: "app", version: "1", body: """
        <dependencies>
          \(dependencyElement("api", "1"))
        </dependencies>
        """))
        let model = try await fixture.read()
        XCTAssertEqual(model.modules.map(\.path).sorted(), [":", ":services:api", ":services:app"])
        let app = try XCTUnwrap(model.modules.first { $0.path == ":services:app" })
        XCTAssertEqual(app.compileProjectDependencies, [MavenModuleDependency(projectPath: ":services:api", sourceSetName: "main")])
        XCTAssertTrue(app.compileClasspathJars.isEmpty)
    }

    func testProjectionClasspathsLanguageLevelAndShards() async throws {
        try fixture.install(group: "com.example", artifact: "lib", version: "1")
        try fixture.writeProject("pom.xml", MavenFixture.pom(group: "com.example", artifact: "app", version: "1", body: """
        <properties><maven.compiler.release>17</maven.compiler.release></properties>
        <dependencies>\(dependencyElement("lib", "1"))</dependencies>
        """))
        try FileManager.default.createDirectory(at: fixture.project.appendingPathComponent("src/main/java"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.project.appendingPathComponent("src/test/java"), withIntermediateDirectories: true)
        let model = try await fixture.read()
        let projected = model.javaProjectModel
        let mainFile = fixture.project.appendingPathComponent("src/main/java/Main.java")
        let testFile = fixture.project.appendingPathComponent("src/test/java/MainTest.java")
        XCTAssertEqual(projected.languageLevel(forFile: mainFile), 17)
        let runtime = try XCTUnwrap(projected.runtimeClasspath(forFile: mainFile))
        XCTAssertEqual(runtime.first?.lastPathComponent, "classes")
        XCTAssertTrue(runtime.map(\.lastPathComponent).contains("lib-1.jar"))
        let testRuntime = try XCTUnwrap(projected.runtimeClasspath(forFile: testFile))
        XCTAssertEqual(testRuntime.prefix(2).map(\.lastPathComponent), ["test-classes", "classes"])
        let paths = JavaIndexPaths(root: fixture.home.appendingPathComponent("index"))
        let shards = try XCTUnwrap(projected.visibleShardPaths(forFile: testFile, paths: paths))
        let jar = try XCTUnwrap(model.modules.first?.compileClasspathJars.first)
        XCTAssertTrue(shards.contains(paths.jarShard(jar).path))
        let mainSources = fixture.project.appendingPathComponent("src/main/java")
        XCTAssertTrue(shards.contains(paths.projectSourcesShard(for: mainSources.standardizedFileURL).path))
        let testTask = try XCTUnwrap(projected.subprojects.first?.testTasks.first)
        XCTAssertEqual(testTask.path, ":test")
        XCTAssertEqual(testTask.resultsDir?.lastPathComponent, "surefire-reports")
    }

    func testMissingParentIsListedForDownload() async throws {
        try fixture.writeProject("pom.xml", """
        <project>
          <modelVersion>4.0.0</modelVersion>
          <parent>
            <groupId>com.example</groupId>
            <artifactId>missing-parent</artifactId>
            <version>1</version>
            <relativePath></relativePath>
          </parent>
          <artifactId>app</artifactId>
        </project>
        """)
        let model = try await fixture.read()
        XCTAssertTrue(model.missing.contains { $0.artifactId == "missing-parent" && $0.type == "pom" })
    }

    func testParseErrorIncludesTheLine() async throws {
        try fixture.writeProject("pom.xml", "<project>\n<artifactId>\n")
        do {
            _ = try await fixture.read()
            XCTFail("expected a read error")
        } catch let error as MavenReadError {
            XCTAssertEqual(error.file.lastPathComponent, "pom.xml")
            XCTAssertNotNil(error.line)
        }
    }

    func testVersionOrder() {
        XCTAssertEqual(MavenVersion.compare("1.0-SNAPSHOT", "1.0"), .orderedAscending)
        XCTAssertEqual(MavenVersion.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(MavenVersion.compare("1.0-alpha-1", "1.0-alpha-2"), .orderedAscending)
        XCTAssertEqual(MavenVersion.compare("1.0", "1.0-sp1"), .orderedAscending)
        XCTAssertEqual(MavenVersion.highest(among: ["1.0", "1.5", "2.0"], matching: "[1.0,2.0)"), "1.5")
    }

    func testConformanceAgainstMavenCLI() async throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "command -v mvn"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        try probe.run()
        probe.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try XCTSkipIf(path.isEmpty, "mvn is not installed")
        try fixture.install(group: "com.example", artifact: "lib", version: "1")
        try fixture.writeProject("pom.xml", MavenFixture.pom(group: "com.example", artifact: "app", version: "1", body: """
        <dependencies>\(dependencyElement("lib", "1"))</dependencies>
        """))
        let model = try await fixture.read()
        let mvn = Process()
        mvn.executableURL = URL(fileURLWithPath: path)
        mvn.currentDirectoryURL = fixture.project
        mvn.arguments = ["-o", "-B", "-ntp", "dependency:build-classpath", "-DincludeScope=compile", "-Dmdep.outputFile=cp.txt"]
        try mvn.run()
        mvn.waitUntilExit()
        try XCTSkipIf(mvn.terminationStatus != 0, "mvn dependency:build-classpath failed")
        let classpath = try String(contentsOf: fixture.project.appendingPathComponent("cp.txt"), encoding: .utf8)
        let expected = try XCTUnwrap(model.modules.first?.compileClasspathJars.map(\.path).joined(separator: ":"))
        XCTAssertTrue(classpath.contains(expected))
    }

    private static func flatten(_ nodes: [MavenDependencyNode]) -> [MavenDependencyNode] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }

    private func dependency(_ artifact: String, _ version: String) -> String {
        "<dependencies>\(dependencyElement(artifact, version))</dependencies>"
    }

    private func dependencyElement(
        _ artifact: String, _ version: String, scope: String? = nil, optional: Bool = false
    ) -> String {
        var xml = """
        <dependency>
          <groupId>com.example</groupId>
          <artifactId>\(artifact)</artifactId>
          <version>\(version)</version>
        """
        if let scope { xml += "\n  <scope>\(scope)</scope>" }
        if optional { xml += "\n  <optional>true</optional>" }
        xml += "\n</dependency>"
        return xml
    }
}

private extension MavenProjectModel {
    func compileNames(_ path: String) -> [String] {
        (modules.first { $0.path == path }?.compileClasspathJars ?? []).map(\.lastPathComponent).sorted()
    }
}

final class MavenFixture {
    let root: URL
    let home: URL
    let project: URL
    let repo: URL
    var store = MavenPOMStore()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("maven-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        repo = home.appendingPathComponent(".m2/repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func writeProject(_ relative: String, _ text: String) throws {
        try write(project.appendingPathComponent(relative), text)
    }

    func install(group: String, artifact: String, version: String, pom: String? = nil, classifier: String = "") throws {
        let folder = MavenLocalRepository.artifactDirectory(
            groupId: group, artifactId: artifact, version: version, repository: repo
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let jarName = MavenLocalRepository.fileName(artifactId: artifact, version: version, classifier: classifier, extension: "jar")
        if pom == nil || classifier.isEmpty {
            try Data().write(to: folder.appendingPathComponent(jarName))
        }
        if let pom {
            let pomName = MavenLocalRepository.fileName(artifactId: artifact, version: version, classifier: "", extension: "pom")
            try pom.write(to: folder.appendingPathComponent(pomName), atomically: true, encoding: .utf8)
        }
    }

    func read(profiles: [String] = [], jdk: Int? = nil) async throws -> MavenProjectModel {
        let options = MavenReadOptions(
            activeProfiles: profiles, jdkFeatureVersion: jdk, userHome: home, environment: [:]
        )
        return try await MavenProjectReader.read(root: project, options: options, store: store)
    }

    static func pom(group: String, artifact: String, version: String, packaging: String = "jar", body: String = "") -> String {
        """
        <project>
          <modelVersion>4.0.0</modelVersion>
          <groupId>\(group)</groupId>
          <artifactId>\(artifact)</artifactId>
          <version>\(version)</version>
          <packaging>\(packaging)</packaging>
          \(body)
        </project>
        """
    }
}
