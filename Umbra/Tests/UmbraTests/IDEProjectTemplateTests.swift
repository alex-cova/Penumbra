import Foundation
import JavaIntelligence
import XCTest
import XcodeProjectFormat
@testable import Umbra

/// The New Project wizard's pure side: what each template generates, the validator and the
/// writer. Nothing here touches a window or the real session files.
final class IDEProjectTemplateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-template-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func options(_ name: String = "My App") -> IDENewProjectOptions {
        IDENewProjectOptions(name: name, parentDirectory: directory)
    }

    private func template(_ id: String) throws -> any IDEProjectTemplate {
        try XCTUnwrap(IDEProjectTemplates.template(id: id), "missing template \(id)")
    }

    // MARK: - Options

    func testProductNameIsAnIdentifier() {
        XCTAssertEqual(options("My App").productName, "My_App")
        XCTAssertEqual(options("3D Viewer").productName, "_3D_Viewer")
        XCTAssertEqual(options("café").productName, "caf_")
        XCTAssertEqual(options("ok_name").productName, "ok_name")
    }

    func testBundleIdentifierUsesOrganizationAndSanitizedName() {
        var options = options("My App_2")
        XCTAssertEqual(options.bundleIdentifier, "com.example.My-App-2")
        options.organizationIdentifier = "org.acme"
        XCTAssertEqual(options.bundleIdentifier, "org.acme.My-App-2")
    }

    // MARK: - Registry

    func testRegistryListsSwiftTemplatesWithUniqueIDs() {
        let ids = IDEProjectTemplates.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(IDEProjectTemplates.families, [.swift, .java])
        XCTAssertEqual(
            Set(ids),
            [
                "swift.xcode.macos-app", "swift.xcode.command-line-tool",
                "swift.package.executable", "swift.package.library",
                "java.maven.application",
            ]
        )
    }

    // MARK: - SwiftPM templates

    func testExecutablePackageFiles() throws {
        let files = try template("swift.package.executable").files(for: options())
        let paths = Set(files.map(\.path))
        XCTAssertEqual(
            paths,
            [
                "Package.swift", ".gitignore", "Sources/My_App/main.swift",
                "Tests/My_AppTests/My_AppTests.swift",
            ]
        )
        let manifest = try text(of: "Package.swift", in: files)
        XCTAssertTrue(manifest.hasPrefix("// swift-tools-version: 6.2"))
        XCTAssertTrue(manifest.contains(".macOS(.v15)"))
        XCTAssertTrue(manifest.contains(".executableTarget(name: \"My_App\")"))
    }

    func testLibraryPackageFilesAndPlatform() throws {
        var options = options("Kit")
        options.minimumMacOS = "14.0"
        options.swiftToolsVersion = "6.0"
        let template = try template("swift.package.library")
        let files = try template.files(for: options)
        let manifest = try text(of: "Package.swift", in: files)
        XCTAssertTrue(manifest.hasPrefix("// swift-tools-version: 6.0"))
        XCTAssertTrue(manifest.contains(".macOS(.v14)"))
        XCTAssertTrue(manifest.contains(".library(name: \"Kit\", targets: [\"Kit\"])"))
        XCTAssertEqual(template.primaryFile(for: options), "Sources/Kit/Kit.swift")
        XCTAssertTrue(files.contains { $0.path == "Sources/Kit/Kit.swift" })
    }

    // MARK: - Xcode templates

    func testAppProjectRoundTripsThroughTheFormatLibrary() throws {
        let options = options()
        let files = try template("swift.xcode.macos-app").files(for: options)
        XCTAssertEqual(
            Set(files.map(\.path)),
            [
                "My App.xcodeproj/project.xcproj", ".gitignore",
                "My_App/My_AppApp.swift", "My_App/ContentView.swift",
                "My_App/Assets.xcassets/Contents.json",
                "My_App/Assets.xcassets/AccentColor.colorset/Contents.json",
                "My_App/Assets.xcassets/AppIcon.appiconset/Contents.json",
                "Tests/My_AppTests.swift",
            ]
        )
        let data = try XCTUnwrap(files.first { $0.path.hasSuffix("project.xcproj") }).data
        let project = try XCSchema.Project(jsonRepresentation: data)
        // Writing what was read gives the same bytes: the output is already canonical.
        XCTAssertEqual(try project.jsonRepresentation(), data)

        XCTAssertEqual(project.targets.map(\.name), ["My_App", "My_AppTests"])
        let testTarget = try XCTUnwrap(project.targets.last).commonProperties
        XCTAssertEqual(testTarget.productTypeID?.rawValue, "com.apple.product-type.bundle.unit-test")
        let target = try XCTUnwrap(project.targets.first).commonProperties
        XCTAssertEqual(target.productTypeID?.rawValue, "com.apple.product-type.application")
        XCTAssertEqual(
            target.buildSettings["PRODUCT_BUNDLE_IDENTIFIER"],
            .string("com.example.My-App")
        )
        XCTAssertEqual(project.configurations.map(\.name.name), ["Debug", "Release"])

        // The source folder is a synchronized folder that belongs to the app target.
        let folders = project.topLevelReferences.compactMap { reference -> XCSchema.Folder? in
            if case .folder(let folder) = reference { return folder }
            return nil
        }
        XCTAssertEqual(folders.map(\.path.path).sorted(), ["My_App", "Tests"])
        let appFolder = try XCTUnwrap(folders.first { $0.path.path == "My_App" })
        XCTAssertEqual(appFolder.targets, [XCSchema.LocalTargetReference(targetName: "My_App")])
        let testsFolder = try XCTUnwrap(folders.first { $0.path.path == "Tests" })
        XCTAssertEqual(testsFolder.targets, [XCSchema.LocalTargetReference(targetName: "My_AppTests")])
    }

    func testCommandLineToolHasNoResourcesPhaseOrAssets() throws {
        let files = try template("swift.xcode.command-line-tool").files(for: options("Tool"))
        XCTAssertEqual(
            Set(files.map(\.path)),
            ["Tool.xcodeproj/project.xcproj", ".gitignore", "Tool/main.swift", "Tests/ToolTests.swift"]
        )
        let data = try XCTUnwrap(files.first { $0.path.hasSuffix("project.xcproj") }).data
        let project = try XCSchema.Project(jsonRepresentation: data)
        let target = try XCTUnwrap(project.targets.first).commonProperties
        XCTAssertEqual(target.productTypeID?.rawValue, "com.apple.product-type.tool")
        XCTAssertFalse(target.buildPhases.contains {
            if case .resources = $0 { return true }
            return false
        })
    }

    func testXcodeOutputIsDeterministic() throws {
        let template = try template("swift.xcode.macos-app")
        let first = try template.files(for: options())
        let second = try template.files(for: options())
        XCTAssertEqual(first, second)
    }

    // MARK: - Validator

    func testValidatorRejectsBadNamesAndOrganizations() throws {
        let app = try template("swift.xcode.macos-app")
        func issues(_ name: String, organization: String = "com.example") -> [IDENewProjectIssue] {
            var options = options(name)
            options.organizationIdentifier = organization
            return IDENewProjectValidator.issues(for: options, template: app)
        }
        XCTAssertEqual(issues("Fine"), [])
        XCTAssertEqual(issues(""), [.emptyName])
        XCTAssertEqual(issues("   "), [.emptyName])
        XCTAssertEqual(issues("a/b").count, 1)
        XCTAssertEqual(issues(".hidden").count, 1)
        XCTAssertEqual(issues("Fine", organization: "nodots"), [.invalidOrganizationIdentifier])
        XCTAssertEqual(issues("Fine", organization: "com..example"), [.invalidOrganizationIdentifier])
    }

    func testPackageTemplatesDoNotNeedAnOrganizationIdentifier() throws {
        var options = options("Fine")
        options.organizationIdentifier = ""
        let package = try template("swift.package.library")
        XCTAssertEqual(IDENewProjectValidator.issues(for: options, template: package), [])
    }

    func testValidatorReportsAnExistingDestination() throws {
        let package = try template("swift.package.library")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Taken"), withIntermediateDirectories: true
        )
        let issues = IDENewProjectValidator.issues(for: options("Taken"), template: package)
        XCTAssertEqual(issues, [.alreadyExists(directory.appendingPathComponent("Taken", isDirectory: true))])
    }

    // MARK: - Maven

    func testMavenApplicationIsAReadableProject() async throws {
        let template = try template("java.maven.application")
        XCTAssertEqual(template.fields, [.organizationIdentifier])
        XCTAssertEqual(template.title, "Java Application (Maven)")
        let app = options("My App")
        let files = try template.files(for: app)
        XCTAssertEqual(
            Set(files.map(\.path)),
            [
                "pom.xml", ".gitignore",
                "src/main/java/com/example/my_app/Main.java",
                "src/test/java/com/example/my_app/MainTest.java",
            ]
        )
        XCTAssertEqual(template.primaryFile(for: app), "src/main/java/com/example/my_app/Main.java")
        XCTAssertFalse(files.contains { $0.path.contains("mvnw") || $0.path.contains(".mvn") })
        let pom = try text(of: "pom.xml", in: files)
        XCTAssertTrue(pom.contains("<groupId>com.example</groupId>"))
        XCTAssertTrue(pom.contains("<artifactId>my_app</artifactId>"))
        XCTAssertTrue(pom.contains("<artifactId>junit-jupiter</artifactId>"))
        XCTAssertTrue(pom.contains("<version>\(IDEMavenApplicationTemplate.junitVersion)</version>"))
        XCTAssertTrue(pom.contains("<artifactId>maven-surefire-plugin</artifactId>"))
        XCTAssertTrue(pom.contains("<version>\(IDEMavenApplicationTemplate.surefireVersion)</version>"))
        let release = JDKLocator().discoverAll().map(\.featureVersion).max() ?? 17
        XCTAssertTrue(pom.contains("<maven.compiler.release>\(release)</maven.compiler.release>"))
        XCTAssertTrue(try text(of: ".gitignore", in: files).contains("target/"))
        var hyphenated = options("Widget")
        hyphenated.organizationIdentifier = "com.example-org"
        XCTAssertEqual(
            template.primaryFile(for: hyphenated),
            "src/main/java/com/example_org/widget/Main.java"
        )

        let root = try IDEProjectWriter.create(template, options: app)
        let home = directory.appendingPathComponent("m2-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let model = try await MavenProjectReader.read(
            root: root,
            options: MavenReadOptions(userHome: home, environment: [:]),
            store: MavenPOMStore()
        )
        let module = try XCTUnwrap(model.modules.first)
        XCTAssertEqual(model.modules.map(\.path), [":"])
        XCTAssertEqual(module.groupId, "com.example")
        XCTAssertEqual(module.artifactId, "my_app")
        XCTAssertEqual(module.languageLevel, release)
        XCTAssertEqual(model.javaProjectModel.gradleVersion, "maven")
        XCTAssertEqual(model.javaProjectModel.subprojects.first?.testTasks.first?.path, ":test")
    }

    // MARK: - Writer

    func testWriterCreatesTheProjectAndLeavesNoStagingFolder() throws {
        let package = try template("swift.package.executable")
        let root = try IDEProjectWriter.create(package, options: options("Hello"))
        XCTAssertEqual(root.lastPathComponent, "Hello")
        for path in ["Package.swift", "Sources/Hello/main.swift", "Tests/HelloTests/HelloTests.swift"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path),
                "missing \(path)"
            )
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, ["Hello"])
    }

    func testWriterRefusesAnExistingFolderAndKeepsItsContents() throws {
        let package = try template("swift.package.library")
        let existing = directory.appendingPathComponent("Keep", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let marker = existing.appendingPathComponent("marker.txt")
        try Data("mine".utf8).write(to: marker)

        XCTAssertThrowsError(try IDEProjectWriter.create(package, options: options("Keep")))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "mine")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, ["Keep"])
    }

    func testWriterRemovesTheStagingFolderWhenATemplateFails() throws {
        struct Broken: IDEProjectTemplate {
            let id = "test.broken"
            let family = IDEProjectFamily.swift
            let title = "Broken"
            let summary = ""
            let systemImage = "xmark"
            let fields: Set<IDENewProjectField> = []
            func primaryFile(for options: IDENewProjectOptions) -> String? { nil }
            func files(for options: IDENewProjectOptions) throws -> [IDEGeneratedFile] {
                [
                    IDEGeneratedFile(path: "ok.txt", text: "x"),
                    IDEGeneratedFile(path: "../escape.txt", text: "x"),
                ]
            }
        }
        XCTAssertThrowsError(try IDEProjectWriter.create(Broken(), options: options("Nope")))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, [])
    }

    // MARK: - Samples for manual verification

    /// Writes one project per template into `$UMBRA_TEMPLATE_SAMPLES` so they can be built with
    /// `xcodebuild` / `swift build`. Skipped unless the variable is set.
    func testWritesSamplesWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["UMBRA_TEMPLATE_SAMPLES"] else {
            throw XCTSkip("Set UMBRA_TEMPLATE_SAMPLES to a directory to write sample projects.")
        }
        let parent = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        for template in IDEProjectTemplates.all {
            let name = template.id.replacingOccurrences(of: "swift.", with: "").replacingOccurrences(of: ".", with: "-")
            let options = IDENewProjectOptions(name: name, parentDirectory: parent)
            try? FileManager.default.removeItem(at: options.rootURL)
            try IDEProjectWriter.create(template, options: options)
        }
    }

    // MARK: - Helpers

    private func text(of path: String, in files: [IDEGeneratedFile]) throws -> String {
        let file = try XCTUnwrap(files.first { $0.path == path }, "missing \(path)")
        return String(decoding: file.data, as: UTF8.self)
    }
}
