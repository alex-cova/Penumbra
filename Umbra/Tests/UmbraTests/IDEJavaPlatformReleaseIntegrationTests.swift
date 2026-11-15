import AppKit
import EditorIntelligence
import Foundation
@testable import JavaIntelligence
import XCTest
@testable import Umbra

/// The production wiring of release-aware platforms: a real `IDEWorkspace` opens a two-module Maven
/// reactor (no Maven process: the POMs are read natively), `IDEJavaSupport` indexes the selected
/// JDK plus release 8 from its `ct.sym`, and each module's files resolve against their own release
/// through the same scope every Java feature uses. Every inspection publication is recorded, so a
/// transient false "Cannot resolve import" during indexing fails the test even if later replaced.
///
/// Needs an installed JDK whose `ct.sym` holds release 8 (skipped otherwise).
@MainActor
final class IDEJavaPlatformReleaseIntegrationTests: XCTestCase {
    private var directory: URL!
    private var workspaces: [IDEWorkspace] = []

    override func setUp() async throws {
        guard let jdk = JDKLocator().select(), JDKPlatformRoot.supportedReleases(of: jdk).contains(8) || jdk.featureVersion == 8 else {
            throw XCTSkip("needs an installed JDK whose ct.sym holds release 8")
        }
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("java-release-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for workspace in workspaces { workspace.teardown() }
        workspaces = []
        IDEWorkspace.isSessionPersistenceEnabled = true
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private final class Recorder {
        var publications: [String: [[String]]] = [:]
        func record(_ url: URL, _ diagnostics: [Diagnostic]) {
            publications[url.lastPathComponent, default: []].append(
                diagnostics.filter { $0.code?.hasPrefix("unresolved-") == true }.map(\.message).sorted())
        }
        func everything(for name: String) -> [String] { (publications[name] ?? []).flatMap { $0 } }
    }

    @discardableResult
    private func write(_ relative: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func pom(artifact: String, properties: String) -> String {
        """
        <project xmlns="http://maven.apache.org/POM/4.0.0">
          <modelVersion>4.0.0</modelVersion>
          <groupId>demo</groupId>
          <artifactId>\(artifact)</artifactId>
          <version>1.0</version>
          <properties>\(properties)</properties>
        </project>
        """
    }

    private static func source(_ name: String) -> String {
        """
        package app;

        import javax.xml.bind.JAXBContext;
        import java.net.http.HttpClient;

        class \(name) {
            JAXBContext context;
            HttpClient client;
            String name;
        }
        """
    }

    private func rows(_ workspace: IDEWorkspace, _ name: String) -> [String] {
        workspace.problems.inspectionDiagnostics.first { $0.key.lastPathComponent == name }?.value
            .filter { $0.code?.hasPrefix("unresolved-") == true }.map(\.message).sorted() ?? []
    }

    private func eventually(_ message: String, seconds: Double = 60, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), message)
    }

    private func mentions(_ rows: [String], _ word: String) -> Bool { rows.contains { $0.contains(word) } }

    func testModulesResolveAgainstTheirOwnReleaseAndFollowAPomChange() async throws {
        try write("pom.xml", """
        <project xmlns="http://maven.apache.org/POM/4.0.0">
          <modelVersion>4.0.0</modelVersion>
          <groupId>demo</groupId>
          <artifactId>root</artifactId>
          <version>1.0</version>
          <packaging>pom</packaging>
          <modules><module>legacy</module><module>modern</module></modules>
        </project>
        """)
        try write("legacy/pom.xml", pom(artifact: "legacy", properties: "<maven.compiler.release>8</maven.compiler.release>"))
        // Source/target alone: the build compiles against the JDK's whole platform.
        try write("modern/pom.xml", pom(artifact: "modern", properties: "<maven.compiler.source>8</maven.compiler.source><maven.compiler.target>8</maven.compiler.target>"))
        let legacy = try write("legacy/src/main/java/app/Legacy.java", Self.source("Legacy"))
        let modern = try write("modern/src/main/java/app/Modern.java", Self.source("Modern"))

        let recorder = Recorder()
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        let original = workspace.javaSupport.onInspectionDiagnostics
        workspace.javaSupport.onInspectionDiagnostics = { url, diagnostics in
            recorder.record(url, diagnostics)
            original?(url, diagnostics)
        }
        workspaces.append(workspace)
        workspace.openProjectFolder(directory)
        await workspace.openDocument(from: legacy)
        await workspace.openDocument(from: modern)

        // Release 8 has JAXB and no java.net.http; the JDK's own platform the reverse.
        await eventually("legacy reports HttpClient only: \(rows(workspace, "Legacy.java")) \(recorder.publications)") {
            mentions(rows(workspace, "Legacy.java"), "HttpClient") && !mentions(rows(workspace, "Legacy.java"), "JAXBContext")
        }
        await eventually("modern reports JAXBContext only: \(rows(workspace, "Modern.java"))") {
            mentions(rows(workspace, "Modern.java"), "JAXBContext") && !mentions(rows(workspace, "Modern.java"), "HttpClient")
        }
        XCTAssertFalse(mentions(recorder.everything(for: "Legacy.java"), "JAXBContext"), "never a transient JAXB false positive")
        XCTAssertFalse(mentions(recorder.everything(for: "Legacy.java"), "String"))
        XCTAssertFalse(mentions(recorder.everything(for: "Modern.java"), "String"))

        // Member level, through the production index and the model's own scopes.
        let model = try XCTUnwrap(workspace.javaSupport.projectModel)
        XCTAssertEqual(model.platformAPI(forFile: legacy), .release(8))
        XCTAssertEqual(model.platformAPI(forFile: modern), .compilerJDK(sourceLevel: 8))
        let scopes = JavaFileResolutionScopes(model: model, paths: JavaIndexPaths.default())
        let index = workspace.javaSupport.javaIndex
        let context = JavaResolutionContext(packageName: "app", imports: [], enclosingTypeQualifiedNames: ["app.Legacy"])
        func staticNames(_ file: URL) async -> Set<String> {
            await scopes.context(for: file).apply {
                Set(await JavaMemberLookup.members(of: .classType(qualifiedName: "java.util.List", arguments: [], outer: nil),
                                                   mode: .staticOnly, context: context, index: index).map(\.name))
            }
        }
        let legacyNames = await staticNames(legacy)
        let modernNames = await staticNames(modern)
        XCTAssertFalse(legacyNames.contains("of"), "List.of is not in release 8")
        XCTAssertTrue(modernNames.contains("of"))
        let legacyFlags = JavacInvocationBuilder.resolve(file: legacy, text: Self.source("Legacy"), kind: .gradle(model))?.platform
        XCTAssertEqual(legacyFlags, .release(8))

        // The build moves the legacy module to release 21: its results follow, without a reopen.
        try write("legacy/pom.xml", pom(artifact: "legacy", properties: "<maven.compiler.release>21</maven.compiler.release>"))
        await eventually("legacy follows release 21: \(rows(workspace, "Legacy.java"))", seconds: 90) {
            mentions(rows(workspace, "Legacy.java"), "JAXBContext") && !mentions(rows(workspace, "Legacy.java"), "HttpClient")
        }
    }

    /// A release the JDK cannot provide (release 7 is in no current `ct.sym`) is not a completed
    /// empty platform and not a reason to judge the module against another release: its
    /// missing-class checks stay pending, and the Problems panel says which API is missing.
    func testAnUnavailableReleaseKeepsItsModulePending() async throws {
        try write("pom.xml", pom(artifact: "old", properties: "<maven.compiler.release>7</maven.compiler.release>"))
        let old = try write("src/main/java/app/Old.java", Self.source("Old"))
        let recorder = Recorder()
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        let original = workspace.javaSupport.onInspectionDiagnostics
        workspace.javaSupport.onInspectionDiagnostics = { url, diagnostics in
            recorder.record(url, diagnostics)
            original?(url, diagnostics)
        }
        workspaces.append(workspace)
        workspace.openProjectFolder(directory)
        await workspace.openDocument(from: old)

        var status: IDEResolutionStatus = .complete
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            status = await workspace.javaSupport.resolutionStatus(for: old)
            if workspace.javaSupport.unavailablePlatformReleases.contains(7), status.message?.contains("Java 7 API") == true { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(workspace.javaSupport.unavailablePlatformReleases.contains(7))
        XCTAssertTrue(status.message?.contains("Java 7 API") == true, "\(status)")
        let pending = await workspace.javaSupport.inspectionService.isResolutionPending(for: old)
        XCTAssertTrue(pending)
        XCTAssertEqual(recorder.everything(for: "Old.java"), [], "no missing-class report against a stand-in platform")
    }
}
