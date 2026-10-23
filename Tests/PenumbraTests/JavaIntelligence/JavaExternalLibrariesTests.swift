import XCTest
@testable import JavaIntelligence

final class JavaExternalLibrariesTests: XCTestCase {
    // MARK: Coordinates

    func testGradleCacheJar() {
        let jar = URL(fileURLWithPath: "/Users/a/.gradle/caches/modules-2/files-2.1/org.slf4j/slf4j-api/2.0.9/abc123/slf4j-api-2.0.9.jar")
        let coordinates = JavaLibraryCoordinates.parse(jar: jar)
        XCTAssertEqual(coordinates.origin, .gradle)
        XCTAssertEqual(coordinates.group, "org.slf4j")
        XCTAssertEqual(coordinates.artifact, "slf4j-api")
        XCTAssertEqual(coordinates.version, "2.0.9")
        XCTAssertNil(coordinates.classifier)
        XCTAssertEqual(coordinates.label, "Gradle: org.slf4j:slf4j-api:2.0.9")
    }

    func testGradleCacheClassifier() {
        let jar = URL(fileURLWithPath: "/h/.gradle/caches/modules-2/files-2.1/io.netty/netty-transport-native-epoll/4.1.0/h/netty-transport-native-epoll-4.1.0-linux-x86_64.jar")
        let coordinates = JavaLibraryCoordinates.parse(jar: jar)
        XCTAssertEqual(coordinates.classifier, "linux-x86_64")
        XCTAssertEqual(coordinates.label, "Gradle: io.netty:netty-transport-native-epoll:4.1.0")
    }

    func testMavenRepositoryJar() {
        let jar = URL(fileURLWithPath: "/Users/a/.m2/repository/com/google/guava/guava/33.0.0-jre/guava-33.0.0-jre.jar")
        let coordinates = JavaLibraryCoordinates.parse(jar: jar)
        XCTAssertEqual(coordinates.origin, .maven)
        XCTAssertEqual(coordinates.group, "com.google.guava")
        XCTAssertEqual(coordinates.label, "Maven: com.google.guava:guava:33.0.0-jre")
    }

    func testMavenJarWithMismatchedNameIsLocal() {
        let jar = URL(fileURLWithPath: "/Users/a/.m2/repository/com/x/lib/1.0/renamed.jar")
        XCTAssertEqual(JavaLibraryCoordinates.parse(jar: jar).origin, .local)
    }

    func testLocalJarUsesFileName() {
        let coordinates = JavaLibraryCoordinates.parse(jar: URL(fileURLWithPath: "/work/libs/vendor.jar"))
        XCTAssertEqual(coordinates.origin, .local)
        XCTAssertEqual(coordinates.label, "vendor.jar")
    }

    // MARK: Library list

    func testListDedupesAndSortsByLabel() {
        let beta = URL(fileURLWithPath: "/h/.m2/repository/org/b/beta/1.0/beta-1.0.jar")
        let alpha = URL(fileURLWithPath: "/h/.m2/repository/org/a/Alpha/1.0/Alpha-1.0.jar")
        let local = URL(fileURLWithPath: "/work/zed.jar")
        let processor = URL(fileURLWithPath: "/h/.m2/repository/org/p/proc/1.0/proc-1.0.jar")
        let model = JavaGradleProjectModel(formatVersion: 8, gradleVersion: "maven", subprojects: [
            .init(path: ":", directory: URL(fileURLWithPath: "/work"), languageLevel: 21, sourceSets: [
                .init(name: "main", compileClasspathJars: [beta, alpha], runtimeClasspathJars: [beta, local],
                      annotationProcessorJars: [processor]),
                .init(name: "test", compileClasspathJars: [alpha])
            ])
        ])
        let labels = JavaExternalLibrary.list(from: model).map(\.label)
        XCTAssertEqual(labels, ["Maven: org.a:Alpha:1.0", "Maven: org.b:beta:1.0", "zed.jar"])
    }

    // MARK: Archive contents

    func testJarGroupsPackagesAndSkipsNoise() {
        let nodes = JavaArchiveContents.nodes(entries: [
            "META-INF/MANIFEST.MF",
            "META-INF/versions/9/module-info.class",
            "META-INF/versions/9/org/x/Foo.class",
            "module-info.class",
            "org/x/Foo.class",
            "org/x/Foo$Inner.class",
            "org/x/package-info.class",
            "org/x/Bar.class",
            "org/x/messages.properties",
            "org/x/sub/",
            "org/y/Baz.class",
            "LICENSE"
        ], layout: .jar)
        XCTAssertEqual(nodes.map(\.name), ["META-INF", "org.x", "org.y", "LICENSE"])
        XCTAssertEqual(nodes[0].kind, .folder)
        XCTAssertEqual(nodes[0].children.map(\.name), ["MANIFEST.MF"])
        XCTAssertEqual(nodes[1].kind, .package)
        XCTAssertEqual(nodes[1].children.map(\.name), ["Bar", "Foo", "messages.properties"])
        XCTAssertEqual(nodes[1].children.first?.qualifiedName, "org.x.Bar")
        XCTAssertEqual(nodes[3].kind, .resource)
    }

    func testDefaultPackage() {
        let nodes = JavaArchiveContents.nodes(entries: ["Main.class"], layout: .jar)
        XCTAssertEqual(nodes.map(\.name), ["(default package)"])
        XCTAssertEqual(nodes.first?.children.first?.qualifiedName, "Main")
    }

    func testJDKSourcesGroupByModule() {
        let nodes = JavaArchiveContents.nodes(entries: [
            "java.base/module-info.java",
            "java.base/java/lang/String.java",
            "java.base/java/util/List.java",
            "java.sql/java/sql/Connection.java"
        ], layout: .moduleRooted)
        XCTAssertEqual(nodes.map(\.name), ["java.base", "java.sql"])
        XCTAssertEqual(nodes[0].children.map(\.name), ["java.lang", "java.util"])
        XCTAssertEqual(nodes[0].children[0].children.first?.qualifiedName, "java.lang.String")
        XCTAssertEqual(nodes[1].children.first?.children.first?.qualifiedName, "java.sql.Connection")
    }

    func testIDsAreUniqueAcrossModules() {
        let nodes = JavaArchiveContents.nodes(entries: [
            "a/p/X.java", "b/p/X.java"
        ], layout: .moduleRooted)
        func ids(_ node: JavaArchiveNode) -> [String] { [node.id] + node.children.flatMap(ids) }
        let all = nodes.flatMap(ids)
        XCTAssertEqual(all.count, Set(all).count)
    }
}

final class JavaLibraryResourceExtractionTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-resource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testExtractsAResourceUnderAttachedSourcesAndReusesTheCopy() throws {
        let content = scratch.appendingPathComponent("content", isDirectory: true)
        try FileManager.default.createDirectory(at: content.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try "Manifest-Version: 1.0\n".write(
            to: content.appendingPathComponent("META-INF/MANIFEST.MF"), atomically: true, encoding: .utf8
        )
        let jar = scratch.appendingPathComponent("lib.jar")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = content
        zip.arguments = ["-qr", jar.path, "."]
        try zip.run()
        zip.waitUntilExit()

        let cache = scratch.appendingPathComponent("cache", isDirectory: true)
        let url = try XCTUnwrap(JavaAttachedSources.extractResource(entry: "META-INF/MANIFEST.MF", from: jar, cacheRoot: cache))
        XCTAssertTrue(JavaAttachedSources.isExtractedSource(url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Manifest-Version: 1.0\n")

        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let again = try XCTUnwrap(JavaAttachedSources.extractResource(entry: "META-INF/MANIFEST.MF", from: jar, cacheRoot: cache))
        XCTAssertEqual(again, url)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, modified)
    }

    func testMissingEntryIsNil() throws {
        let jar = scratch.appendingPathComponent("missing.jar")
        XCTAssertNil(JavaAttachedSources.extractResource(entry: "a/b.txt", from: jar, cacheRoot: scratch))
    }
}
