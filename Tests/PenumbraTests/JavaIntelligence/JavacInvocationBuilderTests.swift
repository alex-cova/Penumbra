import XCTest
@testable import JavaIntelligence

final class JavacInvocationBuilderTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    /// A fake JDK home whose `bin/javac` is an executable file (contents never run).
    private func makeJDK(feature: Int = 21, withJavac: Bool = true) throws -> JDKInstallation {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("jdk-\(UUID().uuidString)")
        directories.append(home)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("bin"), withIntermediateDirectories: true)
        if withJavac {
            let javac = home.appendingPathComponent("bin/javac")
            try "#!/bin/sh\n".write(to: javac, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: javac.path)
        }
        return JDKInstallation(home: home, featureVersion: feature, versionString: "\(feature).0.1", vendor: nil)
    }

    private let work = URL(fileURLWithPath: "/tmp/work-1")

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private func model(_ subprojects: [JavaGradleProjectModel.Subproject]) -> JavaGradleProjectModel {
        JavaGradleProjectModel(formatVersion: 1, gradleVersion: "8.5", subprojects: subprojects)
    }

    func testGradleFileGetsClasspathSourcepathAndRelease() throws {
        let jdk = try makeJDK(feature: 21)
        let app = JavaGradleProjectModel.Subproject(
            path: ":app", directory: URL(fileURLWithPath: "/p/app"),
            sourceDirs: [URL(fileURLWithPath: "/p/app/src/main/java")],
            languageLevel: 17,
            compileClasspathJars: [URL(fileURLWithPath: "/jars/a.jar"), URL(fileURLWithPath: "/jars/b.jar")]
        )
        let invocation = try XCTUnwrap(JavacInvocationBuilder.build(
            file: URL(fileURLWithPath: "/p/app/src/main/java/com/x/Foo.java"),
            text: "package com.x;\nclass Foo {}",
            kind: .gradle(model([app])), jdk: jdk, workDirectory: work
        ))
        let args = invocation.arguments
        XCTAssertEqual(invocation.executable, jdk.javac)
        XCTAssertEqual(value(after: "--release", in: args), "17")
        XCTAssertEqual(value(after: "-classpath", in: args), "/jars/a.jar:/jars/b.jar")
        XCTAssertEqual(value(after: "-sourcepath", in: args), "/p/app/src/main/java")
        XCTAssertTrue(args.contains("-proc:none"))
        XCTAssertEqual(args.last, "/tmp/work-1/src/com/x/Foo.java")
        XCTAssertEqual(invocation.bufferFile.path, "/tmp/work-1/src/com/x/Foo.java")
        XCTAssertEqual(invocation.environment["JAVA_HOME"], jdk.home.path)
    }

    func testReleaseIsCappedAtJDKFeatureVersionAndOmittedWhenUnknownOrUnsupported() {
        XCTAssertEqual(JavacInvocationBuilder.release(languageLevel: 21, jdkFeatureVersion: 17), 17)
        XCTAssertEqual(JavacInvocationBuilder.release(languageLevel: 11, jdkFeatureVersion: 21), 11)
        XCTAssertNil(JavacInvocationBuilder.release(languageLevel: nil, jdkFeatureVersion: 21))
        XCTAssertNil(JavacInvocationBuilder.release(languageLevel: 11, jdkFeatureVersion: 8))
        XCTAssertNil(JavacInvocationBuilder.release(languageLevel: 7, jdkFeatureVersion: 21))
    }

    func testSourcepathIncludesProjectDependenciesAndMainForTestFiles() throws {
        let jdk = try makeJDK()
        let lib = JavaGradleProjectModel.Subproject(
            path: ":lib", directory: URL(fileURLWithPath: "/p/lib"),
            sourceDirs: [URL(fileURLWithPath: "/p/lib/src/main/java")]
        )
        let app = JavaGradleProjectModel.Subproject(
            path: ":app", directory: URL(fileURLWithPath: "/p/app"),
            sourceSets: [
                .init(name: "main", sourceDirs: [URL(fileURLWithPath: "/p/app/src/main/java")]),
                .init(
                    name: "test",
                    sourceDirs: [URL(fileURLWithPath: "/p/app/src/test/java")],
                    projectDependencies: [.init(projectPath: ":lib", sourceSetName: "main")]
                ),
            ]
        )
        let invocation = try XCTUnwrap(JavacInvocationBuilder.build(
            file: URL(fileURLWithPath: "/p/app/src/test/java/FooTest.java"),
            text: "class FooTest {}", kind: .gradle(model([app, lib])), jdk: jdk, workDirectory: work
        ))
        XCTAssertEqual(
            value(after: "-sourcepath", in: invocation.arguments),
            "/p/app/src/test/java:/p/app/src/main/java:/p/lib/src/main/java"
        )
    }

    func testFileOutsideEverySourceSetIsSkipped() throws {
        let jdk = try makeJDK()
        let app = JavaGradleProjectModel.Subproject(
            path: ":app", directory: URL(fileURLWithPath: "/p/app"),
            sourceDirs: [URL(fileURLWithPath: "/p/app/src/main/java")]
        )
        XCTAssertNil(JavacInvocationBuilder.build(
            file: URL(fileURLWithPath: "/elsewhere/Foo.java"), text: "class Foo {}",
            kind: .gradle(model([app])), jdk: jdk, workDirectory: work
        ))
    }

    func testJDKWithoutJavacIsSkipped() throws {
        let jdk = try makeJDK(withJavac: false)
        XCTAssertNil(jdk.javac)
        XCTAssertNil(JavacInvocationBuilder.build(
            file: URL(fileURLWithPath: "/p/Foo.java"), text: "class Foo {}", kind: .plainFolder, jdk: jdk, workDirectory: work
        ))
    }

    func testLombokJarOnClasspathEnablesItAsProcessor() throws {
        let jdk = try makeJDK()
        let app = JavaGradleProjectModel.Subproject(
            path: ":app", directory: URL(fileURLWithPath: "/p/app"),
            sourceDirs: [URL(fileURLWithPath: "/p/app/src/main/java")],
            compileClasspathJars: [URL(fileURLWithPath: "/jars/guava.jar"), URL(fileURLWithPath: "/jars/lombok-1.18.30.jar")]
        )
        let invocation = try XCTUnwrap(JavacInvocationBuilder.build(
            file: URL(fileURLWithPath: "/p/app/src/main/java/Foo.java"), text: "class Foo {}",
            kind: .gradle(model([app])), jdk: jdk, workDirectory: work
        ))
        XCTAssertEqual(value(after: "-processorpath", in: invocation.arguments), "/jars/lombok-1.18.30.jar")
        XCTAssertFalse(invocation.arguments.contains("-proc:none"))
    }

    private func generatedApp(processorJars: [String], classpath: [String]) -> JavaGradleProjectModel.Subproject {
        let set = JavaGradleProjectModel.SourceSet(
            name: "main",
            sourceDirs: [URL(fileURLWithPath: "/p/app/src/main/java")],
            compileClasspathJars: classpath.map { URL(fileURLWithPath: $0) },
            generatedSourceDirs: [URL(fileURLWithPath: "/p/app/build/generated/ap")],
            annotationProcessorJars: processorJars.map { URL(fileURLWithPath: $0) }
        )
        return .init(path: ":app", directory: URL(fileURLWithPath: "/p/app"), sourceSets: [set])
    }

    func testGeneratedDirsJoinSourcepath() throws {
        let jdk = try makeJDK()
        let invocation = try XCTUnwrap(JavacInvocationBuilder.build(
            file: URL(fileURLWithPath: "/p/app/src/main/java/Foo.java"), text: "class Foo {}",
            kind: .gradle(model([generatedApp(processorJars: [], classpath: [])])), jdk: jdk, workDirectory: work
        ))
        XCTAssertEqual(
            value(after: "-sourcepath", in: invocation.arguments),
            "/p/app/src/main/java:/p/app/build/generated/ap"
        )
        XCTAssertTrue(invocation.arguments.contains("-proc:none"))
    }

    func testLombokFromAnnotationProcessorJarsOnly() throws {
        let jdk = try makeJDK()
        let invocation = try XCTUnwrap(JavacInvocationBuilder.build(
            file: URL(fileURLWithPath: "/p/app/src/main/java/Foo.java"), text: "class Foo {}",
            kind: .gradle(model([generatedApp(
                processorJars: ["/ap/mapstruct-processor.jar", "/ap/lombok-1.18.32.jar"], classpath: ["/jars/guava.jar"]
            )])), jdk: jdk, workDirectory: work
        ))
        XCTAssertEqual(value(after: "-processorpath", in: invocation.arguments), "/ap/lombok-1.18.32.jar")
        XCTAssertFalse(invocation.arguments.contains("-proc:none"))
    }

    func testProcessorJarLombokPreferredOverClasspathLombok() throws {
        let jdk = try makeJDK()
        let invocation = try XCTUnwrap(JavacInvocationBuilder.build(
            file: URL(fileURLWithPath: "/p/app/src/main/java/Foo.java"), text: "class Foo {}",
            kind: .gradle(model([generatedApp(
                processorJars: ["/ap/lombok-2.jar"], classpath: ["/jars/lombok-1.jar"]
            )])), jdk: jdk, workDirectory: work
        ))
        XCTAssertEqual(value(after: "-processorpath", in: invocation.arguments), "/ap/lombok-2.jar")
    }

    func testNonLombokProcessorsStayOff() throws {
        let jdk = try makeJDK()
        let invocation = try XCTUnwrap(JavacInvocationBuilder.build(
            file: URL(fileURLWithPath: "/p/app/src/main/java/Foo.java"), text: "class Foo {}",
            kind: .gradle(model([generatedApp(processorJars: ["/ap/mapstruct-processor.jar"], classpath: [])])),
            jdk: jdk, workDirectory: work
        ))
        XCTAssertTrue(invocation.arguments.contains("-proc:none"))
        XCTAssertNil(value(after: "-processorpath", in: invocation.arguments))
    }

    func testPlainFolderInfersPackageRoot() throws {
        let jdk = try makeJDK()
        let invocation = try XCTUnwrap(JavacInvocationBuilder.build(
            file: URL(fileURLWithPath: "/proj/src/com/acme/Foo.java"),
            text: "// header\npackage com.acme;\n\nclass Foo {}", kind: .plainFolder, jdk: jdk, workDirectory: work
        ))
        XCTAssertEqual(value(after: "-sourcepath", in: invocation.arguments), "/proj/src")
        XCTAssertNil(value(after: "-classpath", in: invocation.arguments))
        XCTAssertNil(value(after: "--release", in: invocation.arguments))
    }

    func testPlainFolderWithMismatchedLayoutUsesTheFilesDirectory() {
        XCTAssertEqual(
            JavacInvocationBuilder.sourceRoot(for: URL(fileURLWithPath: "/proj/loose/Foo.java"), packageName: "com.acme").path,
            "/proj/loose"
        )
        XCTAssertEqual(
            JavacInvocationBuilder.sourceRoot(for: URL(fileURLWithPath: "/proj/Foo.java"), packageName: nil).path,
            "/proj"
        )
    }

    func testPackageDeclarationParsing() {
        XCTAssertEqual(JavacInvocationBuilder.packageDeclaration(in: "package a.b.c;\nclass X {}"), "a.b.c")
        XCTAssertEqual(JavacInvocationBuilder.packageDeclaration(in: "/* c */\n  package   a ;"), "a")
        XCTAssertNil(JavacInvocationBuilder.packageDeclaration(in: "class X { String s = \"package a;\"; }"))
    }
}
