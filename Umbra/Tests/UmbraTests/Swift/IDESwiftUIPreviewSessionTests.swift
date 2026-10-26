import AppKit
import EditorIntelligence
import Foundation
import SwiftIntelligence
import XCTest
@testable import Umbra

/// The preview session: what it does with a file that has no preview, an untrusted folder or a
/// failing build (a fake runner), and, with `UMBRA_PREVIEW_INTEGRATION=1`, a real build, host
/// and frame through SubprocessKit.
@MainActor
final class IDESwiftUIPreviewSessionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-preview-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Fakes

    private final class FakeRunner: IDESwiftUIPreviewProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(executable: String, arguments: [String])] = []
        var buildOutput = ""
        var buildStatus: Int32 = 0
        /// Per call index: how long that call takes and what it prints. Beyond the list, `buildOutput`.
        var script: [(delay: Duration, output: String)] = []

        var commands: [[String]] { lock.withLock { calls.map(\.arguments) } }

        func run(
            executable: String, arguments: [String], workingDirectory: URL?,
            onOutput: @escaping @Sendable (String) -> Void
        ) async -> IDESwiftUIPreviewRunResult {
            let index = lock.withLock { () -> Int in
                calls.append((executable, arguments))
                return calls.count - 1
            }
            var output = buildOutput
            if index < script.count {
                try? await Task.sleep(for: script[index].delay)
                output = script[index].output
            }
            onOutput(output)
            return IDESwiftUIPreviewRunResult(status: buildStatus, output: output, cancelled: Task.isCancelled)
        }

        func startHost(
            executable: String, arguments: [String], workingDirectory: URL?,
            onOutput: @escaping @Sendable (String) -> Void
        ) throws -> any IDESwiftUIPreviewHostProcess {
            struct Unexpected: Error {}
            throw Unexpected()
        }
    }

    private func makeSession(
        file: (url: URL, text: String)?,
        fileProvider: (@MainActor () -> (url: URL, text: String)?)? = nil,
        package: (root: URL, target: String)? = nil,
        buildSystem: SwiftPreviewBuildPlan.BuildSystem = .swiftPM,
        trusted: Bool = true,
        toolchain: IDESwiftUIPreviewToolchain? = IDESwiftUIPreviewToolchain(swift: "/usr/bin/swift", swiftc: "/usr/bin/swiftc"),
        runner: any IDESwiftUIPreviewProcessRunning,
        published: @escaping @MainActor ([URL: [Diagnostic]]) -> Void = { _ in }
    ) -> IDESwiftUIPreviewSession {
        let context = IDESwiftUIPreviewContext(
            activeFile: { fileProvider?() ?? file },
            package: { _ in package.map { IDESwiftUIPreviewPackage(root: $0.root, target: $0.target, buildSystem: buildSystem) } },
            ensureTrusted: { _ in trusted },
            toolchain: { toolchain },
            publishDiagnostics: published,
            bufferText: { _ in nil }
        )
        return IDESwiftUIPreviewSession(context: context, runner: runner, cacheRoot: directory.appendingPathComponent("cache"))
    }

    private func waitUntil(seconds: Double = 8, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private let url = URL(fileURLWithPath: "/p/Pkg/Sources/UI/Banner.swift")

    // MARK: Failure paths

    func testAFileWithNoPreviewSaysSoAndRunsNothing() async {
        let runner = FakeRunner()
        let session = makeSession(
            file: (url, "import SwiftUI\nstruct A: View { var body: some View { Text(\"a\") } }\n"),
            package: (URL(fileURLWithPath: "/p/Pkg"), "UI"), runner: runner
        )
        session.refresh()
        let reached = await waitUntil { session.phase == .noPreviews }
        XCTAssertTrue(reached, "\(session.phase)")
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertTrue(session.blocks.isEmpty)
    }

    func testAFileOutsideAPackageIsRefusedWithAReason() async {
        let session = makeSession(file: (url, "#Preview { Text(\"a\") }"), package: nil, runner: FakeRunner())
        session.refresh()
        let reached = await waitUntil { if case .failed = session.phase { return true } else { return false } }
        XCTAssertTrue(reached)
        guard case .failed(let message) = session.phase else { return XCTFail("\(session.phase)") }
        XCTAssertTrue(message.contains("SwiftPM"), message)
        XCTAssertEqual(session.blocks.count, 1, "the previews were still read")
    }

    func testAnUntrustedFolderBuildsNothing() async {
        let runner = FakeRunner()
        let session = makeSession(
            file: (url, "#Preview { Text(\"a\") }"), package: (URL(fileURLWithPath: "/p/Pkg"), "UI"),
            trusted: false, runner: runner
        )
        session.refresh()
        let reached = await waitUntil { if case .failed = session.phase { return true } else { return false } }
        XCTAssertTrue(reached)
        XCTAssertTrue(runner.commands.isEmpty, "nothing ran before the user trusted the folder")
    }

    func testAMissingToolchainIsReported() async {
        let session = makeSession(
            file: (url, "#Preview { Text(\"a\") }"), package: (URL(fileURLWithPath: "/p/Pkg"), "UI"),
            toolchain: nil, runner: FakeRunner()
        )
        session.refresh()
        let reached = await waitUntil { if case .failed = session.phase { return true } else { return false } }
        XCTAssertTrue(reached)
        guard case .failed(let message) = session.phase else { return XCTFail("\(session.phase)") }
        XCTAssertTrue(message.contains("toolchain"), message)
    }

    func testABuildErrorIsPublishedToProblemsAndSummarised() async throws {
        let source = "import SwiftUI\n#Preview { Text(\"a\") }\n"
        let file = directory.appendingPathComponent("Banner.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let runner = FakeRunner()
        runner.buildStatus = 1
        runner.buildOutput = "\(file.path):2:12: error: cannot find 'Nope' in scope\n"
        var published: [[URL: [Diagnostic]]] = []
        let session = makeSession(
            file: (file, source), package: (directory, "UI"), runner: runner,
            published: { published.append($0) }
        )
        session.refresh()
        let reached = await waitUntil { if case .failed = session.phase { return true } else { return false } }
        XCTAssertTrue(reached, "\(session.phase)")
        guard case .failed(let message) = session.phase else { return XCTFail() }
        XCTAssertTrue(message.contains("Banner.swift:2:12: cannot find 'Nope' in scope"), message)
        let last = try XCTUnwrap(published.last)
        XCTAssertEqual(last[file.standardizedFileURL]?.first?.severity, .error)
        // Only the build ran; nothing was linked after it failed.
        XCTAssertEqual(runner.commands.count, 1)
        XCTAssertEqual(runner.commands.first?.first, "build")
    }

    func testAnOlderRunNeverOverwritesANewerOne() async throws {
        let source = "import SwiftUI\n#Preview { Text(\"a\") }\n"
        let file = directory.appendingPathComponent("Banner.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let runner = FakeRunner()
        runner.buildStatus = 1
        // The first build is slow and fails with "old"; the second fails at once with "new".
        runner.script = [
            (.milliseconds(600), "\(file.path):2:1: error: old\n"),
            (.zero, "\(file.path):2:1: error: new\n")
        ]
        let session = makeSession(file: (file, source), package: (directory, "UI"), runner: runner)
        session.refresh()
        try await Task.sleep(for: .milliseconds(150))
        session.refresh()
        let reached = await waitUntil { if case .failed = session.phase { return true } else { return false } }
        XCTAssertTrue(reached)
        // Let the first build's time run out; its result must not replace the second's.
        try await Task.sleep(for: .milliseconds(900))
        guard case .failed(let message) = session.phase else { return XCTFail("\(session.phase)") }
        XCTAssertTrue(message.contains("new"), message)
        XCTAssertFalse(message.contains("old"), message)
    }

    func testSummaryKeepsTheFirstThreeErrorsWithFileNames() {
        let output = """
        /p/A.swift:1:1: error: first
        /p/B.swift:2:2: warning: ignored
        /p/B.swift:3:3: error: second
        /p/C.swift:4:4: error: third
        /p/D.swift:5:5: error: fourth
        """
        let summary = IDESwiftUIPreviewSession.summary(of: output, fallback: "x")
        XCTAssertEqual(summary, "A.swift:1:1: first\nB.swift:3:3: second\nC.swift:4:4: third")
        XCTAssertEqual(IDESwiftUIPreviewSession.summary(of: "no diagnostics", fallback: "fallback"), "fallback")
    }

    func testToolchainFindsSwiftcBesideSwift() throws {
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let swift = bin.appendingPathComponent("swift"), swiftc = bin.appendingPathComponent("swiftc")
        for file in [swift, swiftc] {
            try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let toolchain = IDESwiftUIPreviewToolchain.beside(swift: swift.path)
        XCTAssertEqual(toolchain.swiftc, swiftc.path)
        XCTAssertEqual(IDESwiftUIPreviewToolchain.beside(swift: "/nowhere/swift").swiftc, "/usr/bin/swiftc")
    }

    // MARK: Artifacts

    private func touch(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    func testALibraryTargetLinksItsMergedObjectAndNotTheIntermediates() throws {
        let out = directory.appendingPathComponent("scratch/out").path
        let bin = out + "/Products/Debug"
        try touch(bin + "/ToyUI.o")
        try touch(bin + "/ToyCore.o")
        try touch(out + "/Intermediates.noindex/ToyUI.build/Debug/ToyUI-t.build/Objects-normal/arm64/A.o")
        try touch(out + "/Intermediates.noindex/ToyUI.build/Debug/ToyUI-t.build/Objects-normal/arm64/ToyUI.swiftmodule/x")
        let located = IDESwiftUIPreviewArtifacts.locate(binPath: bin, module: "ToyUI")
        XCTAssertEqual(located.objects.map { ($0 as NSString).lastPathComponent }, ["ToyCore.o", "ToyUI.o"])
    }

    func testAnExecutableTargetLinksItsPerFileObjectsFromTheIntermediates() throws {
        let out = directory.appendingPathComponent("scratch/out").path
        let bin = out + "/Products/Debug"
        let arm = out + "/Intermediates.noindex/MyApp.build/Debug/MyApp-p.build/Objects-normal/arm64"
        try touch(bin + "/MyApp")
        try touch(bin + "/Dep.o")
        try touch(arm + "/App.o")
        try touch(arm + "/ContentView.o")
        try touch(arm + "/MyApp_lto.o")
        try touch(arm + "/MyApp.swiftmodule")
        let located = IDESwiftUIPreviewArtifacts.locate(binPath: bin, module: "MyApp")
        XCTAssertEqual(located.objects.map { ($0 as NSString).lastPathComponent }.sorted(), ["App.o", "ContentView.o", "Dep.o"])
        XCTAssertEqual(located.modulePaths, [arm])
    }

    func testAnOlderLayoutKeepsObjectsInPerModuleBuildDirectories() throws {
        let bin = directory.appendingPathComponent(".build/arm64-apple-macosx/debug").path
        try touch(bin + "/ToyUI.build/A.swift.o")
        try touch(bin + "/ToyCore.build/B.swift.o")
        try touch(bin + "/Modules/ToyUI.swiftmodule")
        let located = IDESwiftUIPreviewArtifacts.locate(binPath: bin, module: "ToyUI")
        XCTAssertEqual(located.objects.map { ($0 as NSString).lastPathComponent }.sorted(), ["A.swift.o", "B.swift.o"])
        XCTAssertEqual(located.modulePaths, [bin + "/Modules"])
    }

    func testNmOutputNamesTheObjectsThatDefineMain() {
        let output = """
        /p/App.o:
        0000000000000414 T _$s5MyApp0aB4MainV5$mainyyFZ
        0000000000000520 T _main

        /p/ContentView.o:
        0000000000000000 T _$s5MyApp11ContentViewV4bodyQrvg
        """
        let files = ["/p/App.o", "/p/ContentView.o"]
        XCTAssertEqual(IDESwiftUIPreviewArtifacts.objectsDefiningMain(nmOutput: output, files: files), ["/p/App.o"])
        // One file: nm prints no header.
        XCTAssertEqual(
            IDESwiftUIPreviewArtifacts.objectsDefiningMain(nmOutput: "0000 T _main\n", files: ["/p/One.o"]), ["/p/One.o"]
        )
        XCTAssertTrue(IDESwiftUIPreviewArtifacts.objectsDefiningMain(nmOutput: "0000 T _foo\n", files: ["/p/One.o"]).isEmpty)
    }

    func testAViewInAnExecutableTargetIsPreviewedAndReloaded() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_PREVIEW_INTEGRATION"] == "1",
                          "set UMBRA_PREVIEW_INTEGRATION=1 to run the preview pipeline test")
        let package = directory.appendingPathComponent("App")
        let sources = package.appendingPathComponent("Sources/MyApp")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "MyApp", platforms: [.macOS(.v14)], targets: [.executableTarget(name: "MyApp")])
        """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import SwiftUI
        @main struct MyAppMain: App {
            var body: some Scene { WindowGroup { ContentView() } }
        }
        """.write(to: sources.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        func source(_ color: String) -> String {
            """
            import SwiftUI
            struct ContentView: View {
                var body: some View { Text("hello").font(.largeTitle).foregroundStyle(.\(color)) }
            }
            #Preview { ContentView().padding(40) }
            """
        }
        let file = sources.appendingPathComponent("ContentView.swift")
        var current = source("red")
        try current.write(to: file, atomically: true, encoding: .utf8)

        let swift = try XCTUnwrap(IDESwiftPMProjectSystem.resolveSwift(environment: nil))
        let session = makeSession(
            file: nil, fileProvider: { (file, current) },
            package: (package, "MyApp"), toolchain: .beside(swift: swift), runner: IDESwiftUIPreviewSubprocessRunner()
        )
        session.setViewport(CGSize(width: 320, height: 200))
        session.refresh()
        let built = await waitUntil(seconds: 240) { session.phase == .ready && session.frame != nil }
        XCTAssertTrue(built, "phase \(session.phase)\n\(session.log.suffix(20).joined(separator: "\n"))")
        XCTAssertTrue(session.log.contains { $0.contains("App.o") && $0.contains("defines main") }, "the @main object is left out")
        let first = try XCTUnwrap(session.frame?.tiffRepresentation)

        current = source("green")
        try current.write(to: file, atomically: true, encoding: .utf8)
        session.lastReloadReset()
        session.refresh()
        let hot = await waitUntil(seconds: 40) {
            session.lastReload == .hotReload && session.phase == .ready && session.frame?.tiffRepresentation != first
        }
        XCTAssertTrue(hot, "phase \(session.phase)\n\(session.log.suffix(12).joined(separator: "\n"))")
        session.stop()
    }

    // MARK: Window

    func testSwitchingTabsShowsThePreviewOfTheFileNowInFront() async throws {
        let root = directory.appendingPathComponent("pkg", isDirectory: true)
        let sources = root.appendingPathComponent("Sources/ToyUI")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Toy", platforms: [.macOS(.v14)], targets: [.target(name: "ToyUI")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let first = sources.appendingPathComponent("First.swift")
        let second = sources.appendingPathComponent("Second.swift")
        let notes = sources.appendingPathComponent("notes.txt")
        for (file, name) in [(first, "First"), (second, "Second")] {
            try "import SwiftUI\n#Preview(\"\(name)\") { Text(\"\(name)\") }\n".write(to: file, atomically: true, encoding: .utf8)
        }
        try "not swift".write(to: notes, atomically: true, encoding: .utf8)

        let workspace = IDEWorkspace()
        workspace.bootstrap()
        // `bootstrap()` wires the window's modal trust sheet; this folder is simply not trusted.
        workspace.swiftPM.trustPrompt = { _ in false }
        defer { workspace.teardown() }
        workspace.openProjectFolder(root)
        await workspace.openDocument(from: first)
        await workspace.openDocument(from: second)
        await workspace.openDocument(from: notes)
        XCTAssertFalse(workspace.canPreviewSwiftUI, "a text file is not previewed")

        let pane = workspace.workbench.activePane
        func select(_ url: URL) throws {
            let document = try XCTUnwrap(pane.documents.first { $0.url?.standardizedFileURL == url.standardizedFileURL })
            pane.selectDocument(document.id)
            workspace.refreshPresentation()
        }
        try select(second)
        XCTAssertTrue(workspace.canPreviewSwiftUI)
        workspace.toggleSwiftUIPreview()
        let session = try XCTUnwrap(workspace.swiftUIPreview)
        XCTAssertEqual(session.fileName, "Second.swift")

        // Another Swift file in front: its preview is asked for, after a short pause.
        try select(first)
        let switched = await waitUntil(seconds: 5) { session.fileName == "First.swift" }
        XCTAssertTrue(switched, "fileName \(String(describing: session.fileName))")

        // A file that is not Swift leaves the canvas as it is.
        try select(notes)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(session.fileName, "First.swift")
        XCTAssertTrue(workspace.isSwiftUIPreviewVisible)

        workspace.hideSwiftUIPreview()
        XCTAssertFalse(workspace.isSwiftUIPreviewVisible)
        try select(second)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(session.fileName, "First.swift", "a hidden canvas does not follow the tabs")
    }

    func testPreviewsAreGutterLocationsAndNotRunnable() async throws {
        let root = directory.appendingPathComponent("pkg", isDirectory: true)
        let sources = root.appendingPathComponent("Sources/ToyUI")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Toy", platforms: [.macOS(.v14)], targets: [.target(name: "ToyUI")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let text = """
        import SwiftUI

        struct Row: View {
            var body: some View { Text("r") }
        }

        #Preview("Plain") { Row() }

        #Preview { Row().padding() }
        """
        let file = sources.appendingPathComponent("Row.swift")
        try text.write(to: file, atomically: true, encoding: .utf8)

        let workspace = IDEWorkspace()
        workspace.bootstrap()
        workspace.swiftPM.trustPrompt = { _ in false }
        defer { workspace.teardown() }
        workspace.openProjectFolder(root)
        await workspace.openDocument(from: file)

        let provider = try XCTUnwrap(workspace.runProviders.provider(forLanguage: "swift"))
        let document = IDERunDocument(url: file, languageIdentifier: "swift", caretUTF16Offset: 0, text: text)
        let locations = await provider.runnableLocations(in: document)
        let previews = locations.compactMap { location -> (Int, Int, String)? in
            guard case .preview(let index) = location.kind else { return nil }
            return (index, location.line, location.title)
        }
        XCTAssertEqual(previews.map(\.0), [0, 1])
        XCTAssertEqual(previews.map(\.1), [7, 9])
        XCTAssertEqual(previews.map(\.2), ["Plain", "Preview 2"])

        // Run in Context at a preview does not run anything and does not claim to have.
        let atPreview = IDERunDocument(
            url: file, languageIdentifier: "swift",
            caretUTF16Offset: (text as NSString).range(of: "Row().padding()").location, text: text
        )
        let handled = await provider.runInContext(atPreview, mode: .run)
        XCTAssertFalse(handled)

        // The eye opens the canvas on that preview.
        workspace.showSwiftUIPreview(blockIndex: 1)
        XCTAssertTrue(workspace.isSwiftUIPreviewVisible)
        let session = try XCTUnwrap(workspace.swiftUIPreview)
        XCTAssertEqual(session.selectedIndex, 1)
    }

    func testTypingAndScrollingReachTheView() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_PREVIEW_INTEGRATION"] == "1",
                          "set UMBRA_PREVIEW_INTEGRATION=1 to run the preview pipeline test")
        let package = directory.appendingPathComponent("Toy")
        let sources = package.appendingPathComponent("Sources/ToyUI")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Toy", platforms: [.macOS(.v14)], targets: [.target(name: "ToyUI")])
        """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let nameFile = directory.appendingPathComponent("name.txt").path
        let rowFile = directory.appendingPathComponent("row.txt").path
        let source = """
        import SwiftUI

        struct FormView: View {
            @State private var name = ""
            var body: some View {
                VStack(spacing: 0) {
                    TextField("Name", text: $name)
                        .padding(8)
                        .onChange(of: name) { _, value in
                            try? value.write(toFile: "\(nameFile)", atomically: true, encoding: .utf8)
                        }
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(0..<80, id: \\.self) { index in
                                Text("Row \\(index)").frame(maxWidth: .infinity, minHeight: 24).onAppear { record(index) }
                            }
                        }
                    }
                }
            }

            private func record(_ index: Int) {
                let current = Int((try? String(contentsOfFile: "\(rowFile)", encoding: .utf8)) ?? "") ?? 0
                if index > current { try? "\\(index)".write(toFile: "\(rowFile)", atomically: true, encoding: .utf8) }
            }
        }

        #Preview { FormView() }
        """
        let file = sources.appendingPathComponent("FormView.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)

        let swift = try XCTUnwrap(IDESwiftPMProjectSystem.resolveSwift(environment: nil))
        let session = makeSession(
            file: (file, source), package: (package, "ToyUI"),
            toolchain: .beside(swift: swift), runner: IDESwiftUIPreviewSubprocessRunner()
        )
        session.setViewport(CGSize(width: 320, height: 240))
        session.refresh()
        let ready = await waitUntil(seconds: 240) { session.phase == .ready && session.frame != nil }
        XCTAssertTrue(ready, "phase \(session.phase)\n\(session.log.suffix(20).joined(separator: "\n"))")

        func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
        func waitFor(_ path: String, _ expected: (String?) -> Bool) async -> String? {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if expected(read(path)) { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return read(path)
        }

        // Focus the field with a click, then type and delete.
        session.click(at: CGPoint(x: 60, y: 20))
        try await Task.sleep(for: .milliseconds(400))
        session.type("hi")
        let typed = await waitFor(nameFile) { $0 == "hi" }
        XCTAssertEqual(typed, "hi")
        session.perform(command: "deleteBackward:")
        let deleted = await waitFor(nameFile) { $0 == "h" }
        XCTAssertEqual(deleted, "h")
        session.type("ello")
        let word = await waitFor(nameFile) { $0 == "hello" }
        XCTAssertEqual(word, "hello")

        // Scrolling brings later rows in.
        let initial = Int(read(rowFile) ?? "") ?? 0
        XCTAssertLessThan(initial, 20)
        session.scroll(at: CGPoint(x: 160, y: 150), dx: 0, dy: 600)
        let scrolled = await waitFor(rowFile) { (Int($0 ?? "") ?? 0) > 25 }
        XCTAssertGreaterThan(Int(scrolled ?? "") ?? 0, 25, "rows after the first screenful appeared")
        session.stop()
    }

    // MARK: Environment

    func testRightToLeftLanguagesAreKnownAndSizesHaveStableIdentities() {
        let arabic = IDESwiftUIPreviewSession.Language.all.first { $0.identifier == "ar" }
        XCTAssertEqual(arabic?.isRightToLeft, true)
        XCTAssertEqual(IDESwiftUIPreviewSession.Language.all.first { $0.identifier == "he" }?.isRightToLeft, true)
        XCTAssertEqual(IDESwiftUIPreviewSession.Language.all.first { $0.identifier == "fr" }?.isRightToLeft, false)
        XCTAssertFalse(IDESwiftUIPreviewSession.Language.system.isRightToLeft)
        XCTAssertEqual(IDESwiftUIPreviewSession.SizePreset.fixed(width: 320, height: 240).id, "320x240")
        XCTAssertEqual(IDESwiftUIPreviewSession.TextSize.allCases.count, 12)
        XCTAssertEqual(IDESwiftUIPreviewSession.TextSize.large.rawValue, "large")
    }

    func testTheEnvironmentBarReachesTheView() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_PREVIEW_INTEGRATION"] == "1",
                          "set UMBRA_PREVIEW_INTEGRATION=1 to run the preview pipeline test")
        let package = directory.appendingPathComponent("Toy")
        let sources = package.appendingPathComponent("Sources/ToyUI")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Toy", platforms: [.macOS(.v14)], targets: [.target(name: "ToyUI")])
        """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let seen = directory.appendingPathComponent("env.txt").path
        let source = """
        import SwiftUI

        struct EnvironmentView: View {
            @Environment(\\.dynamicTypeSize) private var size
            @Environment(\\.locale) private var locale
            @Environment(\\.layoutDirection) private var direction
            @Environment(\\.colorScheme) private var scheme

            var body: some View {
                let _ = record()
                Text("hello")
            }

            private func record() {
                let line = "\\(size)|\\(locale.identifier)|\\(direction == .rightToLeft ? "rtl" : "ltr")|\\(scheme == .dark ? "dark" : "light")"
                try? line.write(toFile: "\(seen)", atomically: true, encoding: .utf8)
            }
        }

        #Preview { EnvironmentView() }
        """
        let file = sources.appendingPathComponent("EnvironmentView.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)

        let swift = try XCTUnwrap(IDESwiftPMProjectSystem.resolveSwift(environment: nil))
        let session = makeSession(
            file: (file, source), package: (package, "ToyUI"),
            toolchain: .beside(swift: swift), runner: IDESwiftUIPreviewSubprocessRunner()
        )
        session.setViewport(CGSize(width: 320, height: 240))
        session.refresh()
        let ready = await waitUntil(seconds: 240) { session.phase == .ready && session.frame != nil }
        XCTAssertTrue(ready, "phase \(session.phase)\n\(session.log.suffix(20).joined(separator: "\n"))")

        func environment(_ expected: String) async -> String? {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let text = try? String(contentsOfFile: seen, encoding: .utf8), text.hasPrefix(expected) || text.contains(expected) {
                    return text
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return try? String(contentsOfFile: seen, encoding: .utf8)
        }
        let initial = await environment("large|")
        XCTAssertTrue(initial?.hasPrefix("large|") == true, initial ?? "nil")
        XCTAssertTrue(initial?.hasSuffix("|ltr|light") == true, initial ?? "nil")

        session.setTextSize(.xxLarge)
        let big = await environment("xxLarge|")
        XCTAssertTrue(big?.hasPrefix("xxLarge|") == true, big ?? "nil")

        session.setLanguage(IDESwiftUIPreviewSession.Language(identifier: "ar", title: "Arabic"))
        let arabic = await environment("|rtl|")
        XCTAssertTrue(arabic?.contains("ar") == true && arabic?.contains("|rtl|") == true, arabic ?? "nil")

        session.setColorScheme(.dark)
        let dark = await environment("|dark")
        XCTAssertTrue(dark?.hasSuffix("|dark") == true, dark ?? "nil")

        // Back to the defaults, and a fixed window size.
        session.setLanguage(.system)
        session.setTextSize(.large)
        let back = await environment("large|")
        XCTAssertTrue(back?.hasPrefix("large|") == true && back?.contains("|ltr|") == true, back ?? "nil")
        session.setSizePreset(.fixed(width: 640, height: 480))
        let resized = await waitUntil(seconds: 10) { session.frameSize == CGSize(width: 640, height: 480) }
        XCTAssertTrue(resized, "frame size \(session.frameSize)")
        session.stop()
    }

    func testBundleModuleResourcesAreFoundBeforeAndAfterAReload() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_PREVIEW_INTEGRATION"] == "1",
                          "set UMBRA_PREVIEW_INTEGRATION=1 to run the preview pipeline test")
        let package = directory.appendingPathComponent("Toy")
        let sources = package.appendingPathComponent("Sources/ToyUI")
        let resources = sources.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "Toy", platforms: [.macOS(.v14)],
            targets: [.target(name: "ToyUI", resources: [.process("Resources")])]
        )
        """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "bonjour".write(to: resources.appendingPathComponent("greeting.txt"), atomically: true, encoding: .utf8)
        // An asset catalog with a named color: it goes through actool into the resource bundle.
        let catalog = resources.appendingPathComponent("Assets.xcassets")
        let colorSet = catalog.appendingPathComponent("Brand.colorset")
        try FileManager.default.createDirectory(at: colorSet, withIntermediateDirectories: true)
        try #"{"info":{"author":"xcode","version":1}}"#.write(
            to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8
        )
        try """
        {"colors":[{"color":{"color-space":"srgb","components":{"red":"1.0","green":"0.0","blue":"0.0","alpha":"1.0"}},"idiom":"universal"}],"info":{"author":"xcode","version":1}}
        """.write(to: colorSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
        let seen = directory.appendingPathComponent("resource.txt").path
        func source(_ suffix: String) -> String {
            """
            import SwiftUI

            struct GreetingView: View {
                var body: some View {
                    let _ = record()
                    Text("hi")
                }

                private func record() {
                    let url = Bundle.module.url(forResource: "greeting", withExtension: "txt")
                    let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "MISSING"
                    let color = NSColor(named: "Brand", bundle: .module) != nil ? "+color" : "+nocolor"
                    try? (text + color + "\(suffix)").write(toFile: "\(seen)", atomically: true, encoding: .utf8)
                }
            }

            #Preview { GreetingView() }
            """
        }
        let file = sources.appendingPathComponent("GreetingView.swift")
        var current = source("")
        try current.write(to: file, atomically: true, encoding: .utf8)

        let swift = try XCTUnwrap(IDESwiftPMProjectSystem.resolveSwift(environment: nil))
        let session = makeSession(
            file: nil, fileProvider: { (file, current) },
            package: (package, "ToyUI"), toolchain: .beside(swift: swift), runner: IDESwiftUIPreviewSubprocessRunner()
        )
        session.setViewport(CGSize(width: 320, height: 240))
        session.refresh()
        let ready = await waitUntil(seconds: 240) { session.phase == .ready && session.frame != nil }
        XCTAssertTrue(ready, "phase \(session.phase)\n\(session.log.suffix(20).joined(separator: "\n"))")
        func seenText() -> String? { try? String(contentsOfFile: seen, encoding: .utf8) }
        let firstSeen = await waitUntil(seconds: 10) { seenText() != nil }
        XCTAssertTrue(firstSeen)
        XCTAssertEqual(seenText(), "bonjour+color", "the built preview reads the package's resources")

        // A save loads the file as a copy in a module of its own, which has no resources.
        current = source("!")
        try current.write(to: file, atomically: true, encoding: .utf8)
        session.lastReloadReset()
        session.refresh()
        let reloaded = await waitUntil(seconds: 60) { session.lastReload != nil && session.phase == .ready }
        XCTAssertTrue(reloaded, "phase \(session.phase)\n\(session.log.suffix(12).joined(separator: "\n"))")
        let updated = await waitUntil(seconds: 10) { seenText() == "bonjour+color!" }
        XCTAssertTrue(updated, "saw \(seenText() ?? "nil"), last reload \(String(describing: session.lastReload))\n\(session.log.suffix(12).joined(separator: "\n"))")
        XCTAssertEqual(session.lastReload, .hotReload, "the copy should compile against the module's Bundle.module")
        session.stop()
    }

    // MARK: Xcode projects

    func testTheXcodeModelNamesTheTargetAFileIsCompiledIn() throws {
        // project.xcproj (a folder with target membership).
        let template = try XCTUnwrap(IDEProjectTemplates.template(id: "swift.xcode.macos-app"))
        let options = IDENewProjectOptions(name: "Modeled", parentDirectory: directory)
        let root = try IDEProjectWriter.create(template, options: options)
        let project = try XCTUnwrap(IDEXcodeProjectModel.findProject(in: root))
        let model = try IDEXcodeProjectModel.load(projectURL: project)
        let view = root.appendingPathComponent("Modeled/ContentView.swift")
        XCTAssertEqual(model.targets(containing: view), ["Modeled"])
        XCTAssertTrue(model.targets(containing: root.appendingPathComponent("Other/File.swift")).isEmpty)

        // project.pbxproj: a synchronized group, a classic group with a Sources phase, and a test target.
        let pbxproj = """
        {
          objects = {
            P = { isa = PBXProject; mainGroup = G0; targets = (T1, T2); };
            G0 = { isa = PBXGroup; children = (SYNC, CLASSIC, TESTS); sourceTree = "<group>"; };
            SYNC = { isa = PBXFileSystemSynchronizedRootGroup; path = Synced; sourceTree = "<group>"; };
            CLASSIC = { isa = PBXGroup; path = Classic; sourceTree = "<group>"; children = (F1); };
            F1 = { isa = PBXFileReference; path = Listed.swift; sourceTree = "<group>"; };
            TESTS = { isa = PBXGroup; path = Tests; sourceTree = "<group>"; children = (F2); };
            F2 = { isa = PBXFileReference; path = AppTests.swift; sourceTree = "<group>"; };
            B1 = { isa = PBXBuildFile; fileRef = F1; };
            B2 = { isa = PBXBuildFile; fileRef = F2; };
            S1 = { isa = PBXSourcesBuildPhase; files = (B1); };
            S2 = { isa = PBXSourcesBuildPhase; files = (B2); };
            T1 = { isa = PBXNativeTarget; name = App; productType = "com.apple.product-type.application";
                   buildPhases = (S1); fileSystemSynchronizedGroups = (SYNC); };
            T2 = { isa = PBXNativeTarget; name = AppTests; productType = "com.apple.product-type.bundle.unit-test";
                   buildPhases = (S2); };
          };
          rootObject = P;
        }
        """
        let classic = directory.appendingPathComponent("Classic.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: classic, withIntermediateDirectories: true)
        try pbxproj.write(to: classic.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        let classicModel = try IDEXcodeProjectModel.load(projectURL: classic)
        XCTAssertEqual(classicModel.targets(containing: directory.appendingPathComponent("Synced/Deep/View.swift")), ["App"])
        XCTAssertEqual(classicModel.targets(containing: directory.appendingPathComponent("Classic/Listed.swift")), ["App"])
        XCTAssertTrue(
            classicModel.targets(containing: directory.appendingPathComponent("Tests/AppTests.swift")).isEmpty,
            "a test target is not what is previewed"
        )
    }

    func testAnXcodeBuildIsAskedForTheHostsArchitectureInItsOwnDirectories() {
        let job = SwiftPreviewBuildPlan.Job(
            packageRoot: "/p/App", scratchPath: "/cache/x", workDirectory: "/cache/work", targetName: "App",
            sourcePath: "/p/App/App/ContentView.swift", sourceText: "", imports: [],
            block: SwiftPreviewBlock(
                kind: .macro, title: nil, index: 0, traits: nil, fullBytes: 0..<0, bodyBytes: 0..<0,
                contentBytes: 0..<0, previewables: [], line: 1
            ),
            buildSystem: .xcode(project: "/p/App/App.xcodeproj")
        )
        let plan = SwiftPreviewBuildPlan(job: job)
        let command = plan.buildCommand
        XCTAssertEqual(command.tool, SwiftPreviewCommand.Tool.xcodebuild)
        XCTAssertTrue(command.arguments.contains("SYMROOT=/cache/x/Products"))
        XCTAssertTrue(command.arguments.contains("OBJROOT=/cache/x/Intermediates"))
        XCTAssertTrue(command.arguments.contains("ARCHS=arm64"))
        XCTAssertTrue(command.arguments.contains("CODE_SIGNING_ALLOWED=NO"))
        // The macOS SDK even for an iOS app template: its objects would not link into the host, and
        // its products would land in `Debug-iphoneos`, not where `knownBinPath` says.
        let sdk = command.arguments.firstIndex(of: "-sdk")
        XCTAssertEqual(sdk.map { command.arguments[$0 + 1] }, "macosx")
        XCTAssertEqual(plan.knownBinPath, "/cache/x/Products/Debug")
        XCTAssertEqual(plan.intermediatesPath, "/cache/x/Intermediates")
        let flags = command.arguments.first { $0.hasPrefix("OTHER_SWIFT_FLAGS=") } ?? ""
        XCTAssertTrue(flags.contains("$(inherited)") && flags.contains("-enable-testing"))
    }

    func testThePlatformOfAnXcodeTargetIsReadFromItsBuildSettings() {
        let output = """
        Build settings for action build and target App:
            ONLY_ACTIVE_ARCH = YES
            PLATFORM_DISPLAY_NAME = iOS
            PLATFORM_NAME = iphoneos
            PLATFORM_PREFERRED_ARCH = arm64
        """
        XCTAssertEqual(SwiftPreviewBuildPlan.platformName(fromBuildSettings: output), "iphoneos")
        XCTAssertNil(SwiftPreviewBuildPlan.platformName(fromBuildSettings: "error: nothing"))
    }

    func testAnXcodeProjectViewIsPreviewedAndReloaded() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_PREVIEW_INTEGRATION"] == "1",
                          "set UMBRA_PREVIEW_INTEGRATION=1 to run the preview pipeline test")
        let template = try XCTUnwrap(IDEProjectTemplates.template(id: "swift.xcode.macos-app"))
        let options = IDENewProjectOptions(name: "Shown", parentDirectory: directory)
        let root = try IDEProjectWriter.create(template, options: options)
        let project = try XCTUnwrap(IDEXcodeProjectModel.findProject(in: root))
        let file = root.appendingPathComponent("Shown/ContentView.swift")
        func source(_ greeting: String) -> String {
            """
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    Text("\(greeting)").font(.largeTitle).padding(30)
                }
            }

            #Preview { ContentView() }
            """
        }
        var current = source("First")
        try current.write(to: file, atomically: true, encoding: .utf8)

        let swift = try XCTUnwrap(IDESwiftPMProjectSystem.resolveSwift(environment: nil))
        let session = makeSession(
            file: nil, fileProvider: { (file, current) }, package: (root, "Shown"),
            buildSystem: .xcode(project: project.path),
            toolchain: .beside(swift: swift), runner: IDESwiftUIPreviewSubprocessRunner()
        )
        session.setViewport(CGSize(width: 320, height: 200))
        session.refresh()
        let built = await waitUntil(seconds: 300) { session.phase == .ready && session.frame != nil }
        XCTAssertTrue(built, "phase \(session.phase)\n\(session.log.suffix(25).joined(separator: "\n"))")
        XCTAssertEqual(session.lastReload, .build)
        let first = try XCTUnwrap(session.frame?.tiffRepresentation)

        current = source("Second, a longer greeting")
        try current.write(to: file, atomically: true, encoding: .utf8)
        session.lastReloadReset()
        session.refresh()
        let hot = await waitUntil(seconds: 60) {
            session.lastReload == .hotReload && session.phase == .ready && session.frame?.tiffRepresentation != first
        }
        XCTAssertTrue(hot, "phase \(session.phase) last \(String(describing: session.lastReload))\n\(session.log.suffix(12).joined(separator: "\n"))")
        session.stop()
    }

    // MARK: Input

    func testKeysBecomeTextOrEditingCommands() {
        typealias View = IDESwiftUIPreviewInputView
        XCTAssertEqual(View.keyAction(keyCode: 0, modifiers: [], characters: "a"), .text("a"))
        XCTAssertEqual(View.keyAction(keyCode: 0, modifiers: .shift, characters: "A"), .text("A"))
        XCTAssertEqual(View.keyAction(keyCode: 0, modifiers: [], characters: "é"), .text("é"))
        XCTAssertEqual(View.keyAction(keyCode: 51, modifiers: [], characters: "\u{7F}"), .command("deleteBackward:"))
        XCTAssertEqual(View.keyAction(keyCode: 36, modifiers: [], characters: "\r"), .command("insertNewline:"))
        XCTAssertEqual(View.keyAction(keyCode: 48, modifiers: [], characters: "\t"), .command("insertTab:"))
        XCTAssertEqual(View.keyAction(keyCode: 48, modifiers: .shift, characters: "\u{19}"), .command("insertBacktab:"))
        XCTAssertEqual(View.keyAction(keyCode: 123, modifiers: [], characters: "\u{F702}"), .command("moveLeft:"))
        XCTAssertEqual(View.keyAction(keyCode: 123, modifiers: .shift, characters: "\u{F702}"), .command("moveLeftAndModifySelection:"))
        // A shortcut or a key that types nothing is not the preview's.
        XCTAssertEqual(View.keyAction(keyCode: 8, modifiers: .command, characters: "c"), .ignored)
        XCTAssertEqual(View.keyAction(keyCode: 0, modifiers: .control, characters: "\u{01}"), .ignored)
        XCTAssertEqual(View.keyAction(keyCode: 122, modifiers: [], characters: "\u{F704}"), .ignored)
        XCTAssertEqual(View.keyAction(keyCode: 0, modifiers: [], characters: nil), .ignored)
    }

    // MARK: Real pipeline

    func testASaveIsLoadedIntoTheRunningHostWithoutABuild() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_PREVIEW_INTEGRATION"] == "1",
                          "set UMBRA_PREVIEW_INTEGRATION=1 to run the preview pipeline test")
        let package = directory.appendingPathComponent("Toy")
        let sources = package.appendingPathComponent("Sources/ToyUI")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Toy", platforms: [.macOS(.v14)], targets: [.target(name: "ToyUI")])
        """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let tapsFile = directory.appendingPathComponent("taps.txt").path

        // Helper.swift is a second file of the module: changing it needs a build.
        func helper(_ step: Int) -> String { "enum Step { static let value = \(step) }\n" }
        let helperFile = sources.appendingPathComponent("Helper.swift")
        try helper(1).write(to: helperFile, atomically: true, encoding: .utf8)

        func source(label: String = "Tapped", titleStyle: String = "", extraState: String = "") -> String {
            """
            import SwiftUI

            struct Counter: View {
                @State private var taps = 0
                \(extraState)
                var body: some View {
                    VStack {
                        Text("\(label) \\(taps)").font(.title)\(titleStyle)
                        Button("Tap") {
                            taps += Step.value
                            try? "\\(taps)".write(toFile: "\(tapsFile)", atomically: true, encoding: .utf8)
                        }
                    }
                }
            }

            #Preview("Counter") { Counter() }
            """
        }
        let file = sources.appendingPathComponent("Counter.swift")
        var current = source()
        try current.write(to: file, atomically: true, encoding: .utf8)

        let swift = try XCTUnwrap(IDESwiftPMProjectSystem.resolveSwift(environment: nil))
        let session = makeSession(
            file: nil, fileProvider: { (file, current) },
            package: (package, "ToyUI"), toolchain: .beside(swift: swift), runner: IDESwiftUIPreviewSubprocessRunner()
        )
        session.setViewport(CGSize(width: 320, height: 240))
        session.refresh()
        let built = await waitUntil(seconds: 240) { session.phase == .ready && session.frame != nil }
        XCTAssertTrue(built, "phase \(session.phase)\n\(session.log.suffix(20).joined(separator: "\n"))")
        XCTAssertEqual(session.lastReload, .build)

        func tap() async -> String? {
            let before = try? String(contentsOfFile: tapsFile, encoding: .utf8)
            session.click(at: CGPoint(x: 160, y: 130))
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let now = try? String(contentsOfFile: tapsFile, encoding: .utf8)
                if now != before { return now }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return try? String(contentsOfFile: tapsFile, encoding: .utf8)
        }
        /// Writes `text`, refreshes, and waits for the reload of `kind` that follows (a new frame).
        func save(_ text: String, expecting kind: IDESwiftUIPreviewSession.ReloadKind) async -> Bool {
            current = text
            try? text.write(to: file, atomically: true, encoding: .utf8)
            let before = session.frame?.tiffRepresentation
            session.lastReloadReset()
            session.refresh()
            let done = await waitUntil(seconds: kind == .build ? 240 : 40) {
                session.lastReload == kind && session.phase == .ready && session.frame?.tiffRepresentation != before
            }
            if !done {
                XCTFail("expected \(kind): phase \(session.phase) last \(String(describing: session.lastReload))\n"
                    + session.log.suffix(12).joined(separator: "\n"))
            }
            return done
        }

        let t1 = await tap()
        XCTAssertEqual(t1, "1")

        // A modifier changes the body's type. Loaded without a build, and the taps that follow (state
        // changes on the new views) must not take the host down.
        let start = Date()
        let modifier = await save(source(titleStyle: ".foregroundStyle(.red)"), expecting: .hotReload)
        XCTAssertTrue(modifier)
        let reloadSeconds = Date().timeIntervalSince(start)
        print("PREVIEW-RELOAD-SECONDS \(reloadSeconds)")
        XCTAssertLessThan(reloadSeconds, 15, "an edit should not take a build")
        let t2 = await tap()
        XCTAssertEqual(t2, "1")
        let t3 = await tap()
        XCTAssertEqual(t3, "2")

        // A new stored property is no obstacle either: the thunk holds the whole file.
        let stored = await save(source(titleStyle: ".foregroundStyle(.red)", extraState: "@State private var other = 1"), expecting: .hotReload)
        XCTAssertTrue(stored)
        let t4 = await tap()
        XCTAssertEqual(t4, "1")

        // Another file of the module changed: the package is built again, and `Step.value` is 5 now.
        try helper(5).write(to: helperFile, atomically: true, encoding: .utf8)
        let rebuilt = await save(source(label: "Taps"), expecting: .build)
        XCTAssertTrue(rebuilt)
        let t5 = await tap()
        XCTAssertEqual(t5, "5")
        session.stop()
    }

    func testRealBuildShowsAFrameAndAClickChangesIt() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_PREVIEW_INTEGRATION"] == "1",
                          "set UMBRA_PREVIEW_INTEGRATION=1 to run the preview pipeline test")
        let package = directory.appendingPathComponent("Toy")
        let sources = package.appendingPathComponent("Sources/ToyUI")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Toy", platforms: [.macOS(.v14)], targets: [.target(name: "ToyUI")])
        """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let source = """
        import SwiftUI

        struct Counter: View {
            @State private var taps = 0
            var body: some View {
                VStack {
                    Text("Tapped \\(taps)").font(.title)
                    Button("Tap") { taps += 1 }
                }
            }
        }

        #Preview("Counter") { Counter() }
        #Preview("Other") { Text("other") }
        """
        let file = sources.appendingPathComponent("Counter.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)

        // A real toolchain: `swift` on PATH.
        let swift = try XCTUnwrap(IDESwiftPMProjectSystem.resolveSwift(environment: nil))
        let real = makeSession(
            file: (file, source), package: (package, "ToyUI"),
            toolchain: .beside(swift: swift), runner: IDESwiftUIPreviewSubprocessRunner()
        )
        real.setViewport(CGSize(width: 320, height: 240))
        real.refresh()
        let ready = await waitUntil(seconds: 240) { real.phase == .ready && real.frame != nil }
        if !ready { try? real.log.joined(separator: "\n").write(toFile: "/tmp/pv-session-log.txt", atomically: true, encoding: .utf8) }
        XCTAssertTrue(ready, "phase \(real.phase)\n\(real.log.suffix(20).joined(separator: "\n"))")
        XCTAssertEqual(real.blocks.map(\.displayName), ["Counter", "Other"])
        let first = try XCTUnwrap(real.frame?.tiffRepresentation)

        // The button is centred; one click changes `taps`, so the frame changes.
        real.click(at: CGPoint(x: 160, y: 130))
        let changed = await waitUntil(seconds: 20) { real.frame?.tiffRepresentation != first }
        XCTAssertTrue(changed, "the frame did not change after a click")

        // Dark appearance re-renders without a rebuild.
        let beforeDark = try XCTUnwrap(real.frame?.tiffRepresentation)
        real.setColorScheme(.dark)
        let dark = await waitUntil(seconds: 20) { real.frame?.tiffRepresentation != beforeDark }
        XCTAssertTrue(dark)

        // Another preview of the file is a new run.
        real.select(1)
        let other = await waitUntil(seconds: 120) { real.selectedIndex == 1 && real.phase == .ready && real.frame != nil }
        XCTAssertTrue(other, "phase \(real.phase)")
        real.stop()
        XCTAssertEqual(real.phase, .idle)
        XCTAssertNil(real.frame)
    }

    /// A sheet is a window of its own: it has to be drawn into the frame, take the input, and not
    /// show on the display (the preview window used to be pulled onto the screen with it).
    func testASheetIsDrawnIntoTheFrameTakesInputAndStaysOffscreen() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_PREVIEW_INTEGRATION"] == "1",
                          "set UMBRA_PREVIEW_INTEGRATION=1 to run the preview pipeline test")
        let package = directory.appendingPathComponent("Toy")
        let sources = package.appendingPathComponent("Sources/ToyUI")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Toy", platforms: [.macOS(.v14)], targets: [.target(name: "ToyUI")])
        """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let source = """
        import SwiftUI

        struct SheetHost: View {
            @State private var shown = false
            var body: some View {
                Button("Open") { shown = true }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .sheet(isPresented: $shown) {
                        Button { shown = false } label: { Color.red }
                            .buttonStyle(.plain)
                            .frame(width: 200, height: 120)
                    }
            }
        }

        #Preview { SheetHost() }
        """
        let file = sources.appendingPathComponent("SheetHost.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)

        let swift = try XCTUnwrap(IDESwiftPMProjectSystem.resolveSwift(environment: nil))
        let session = makeSession(
            file: (file, source), package: (package, "ToyUI"),
            toolchain: .beside(swift: swift), runner: IDESwiftUIPreviewSubprocessRunner()
        )
        session.setViewport(CGSize(width: 320, height: 240))
        session.refresh()
        let ready = await waitUntil(seconds: 240) { session.phase == .ready && session.frame != nil }
        XCTAssertTrue(ready, "phase \(session.phase)\n\(session.log.suffix(20).joined(separator: "\n"))")

        /// The colour at the middle of the frame, as red, green, blue.
        func centre() -> (r: Double, g: Double, b: Double)? {
            guard let data = session.frame?.tiffRepresentation, let rep = NSBitmapImageRep(data: data),
                  let colour = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
            else { return nil }
            return (Double(colour.redComponent), Double(colour.greenComponent), Double(colour.blueComponent))
        }
        func isRed(_ value: (r: Double, g: Double, b: Double)?) -> Bool {
            guard let value else { return false }
            return value.r > 0.8 && value.g < 0.4 && value.b < 0.4
        }
        /// Windows of the host that lie on a display (the parked window is far outside every one).
        func hostWindowsOnScreen() -> [CGRect] {
            let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            return list.compactMap { info in
                guard (info[kCGWindowOwnerName as String] as? String) == "UmbraPreviewHost",
                      let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
                let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
                return rect.width > 0 && rect.intersects(CGRect(x: -5000, y: -5000, width: 30000, height: 30000)) ? rect : nil
            }
        }
        XCTAssertFalse(isRed(centre()), "the sheet is not open yet")

        // Open the sheet: the button is in the middle of the frame.
        session.click(at: CGPoint(x: 160, y: 120))
        let shown = await waitUntil(seconds: 20) { isRed(centre()) }
        XCTAssertTrue(shown, "the sheet is not in the frame; the middle is \(String(describing: centre()))")
        XCTAssertEqual(hostWindowsOnScreen(), [], "a preview window is on a display")

        // The sheet takes the input: a click on it closes it.
        session.click(at: CGPoint(x: 160, y: 120))
        let closed = await waitUntil(seconds: 20) { !isRed(centre()) }
        XCTAssertTrue(closed, "a click on the sheet did not reach it")
        XCTAssertEqual(hostWindowsOnScreen(), [])
        session.stop()
    }

    /// "Content Size" takes the view's own size (a `.frame` bigger than the panel is no longer
    /// cropped), and zooming out in the canvas size makes the window larger instead of scaling a
    /// window that cuts the view off.
    func testContentSizeAndZoomReachTheHost() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_PREVIEW_INTEGRATION"] == "1",
                          "set UMBRA_PREVIEW_INTEGRATION=1 to run the preview pipeline test")
        let package = directory.appendingPathComponent("Toy")
        let sources = package.appendingPathComponent("Sources/ToyUI")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Toy", platforms: [.macOS(.v14)], targets: [.target(name: "ToyUI")])
        """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let source = """
        import SwiftUI

        struct Big: View {
            var body: some View {
                Color.blue.frame(width: 500, height: 300)
            }
        }

        #Preview { Big() }
        """
        let file = sources.appendingPathComponent("Big.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)

        let swift = try XCTUnwrap(IDESwiftPMProjectSystem.resolveSwift(environment: nil))
        let session = makeSession(
            file: (file, source), package: (package, "ToyUI"),
            toolchain: .beside(swift: swift), runner: IDESwiftUIPreviewSubprocessRunner()
        )
        session.setViewport(CGSize(width: 320, height: 240))
        session.refresh()
        let ready = await waitUntil(seconds: 240) { session.phase == .ready && session.frame != nil }
        XCTAssertTrue(ready, "phase \(session.phase)\n\(session.log.suffix(20).joined(separator: "\n"))")
        XCTAssertEqual(session.frameSize, CGSize(width: 320, height: 240))

        // The view's own size, which is larger than the panel.
        session.setSizePreset(.content)
        let content = await waitUntil(seconds: 20) { session.frameSize == CGSize(width: 500, height: 300) }
        XCTAssertTrue(content, "frame size \(session.frameSize)")
        XCTAssertEqual(session.frame?.size, CGSize(width: 500, height: 300))

        // A phone: the window has its screen's size.
        let device = try XCTUnwrap(IDESwiftUIPreviewDevice.all.first { $0.id == "iphone-16" })
        session.setSizePreset(.device(device))
        let phone = await waitUntil(seconds: 20) { session.frameSize == CGSize(width: 393, height: 852) }
        XCTAssertTrue(phone, "frame size \(session.frameSize)")
        XCTAssertEqual(session.frameDevice, device)

        // The canvas size zoomed out to 50% is a window twice the panel's size.
        session.setSizePreset(.canvas)
        session.setZoom(.scale(0.5))
        let zoomedOut = await waitUntil(seconds: 20) { session.frameSize == CGSize(width: 640, height: 480) }
        XCTAssertTrue(zoomedOut, "frame size \(session.frameSize)")
        session.setZoom(.fit)
        let back = await waitUntil(seconds: 20) { session.frameSize == CGSize(width: 320, height: 240) }
        XCTAssertTrue(back, "frame size \(session.frameSize)")
        session.stop()
    }

    /// A device replaces the size the preview's own `.frame(width:height:)` asks for, keeps the
    /// content out of the status bar and home indicator, and "keep the frame" brings the frame back.
    func testADeviceReplacesThePreviewsFrameAndKeepsTheSafeArea() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_PREVIEW_INTEGRATION"] == "1",
                          "set UMBRA_PREVIEW_INTEGRATION=1 to run the preview pipeline test")
        let package = directory.appendingPathComponent("Toy")
        let sources = package.appendingPathComponent("Sources/ToyUI")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Toy", platforms: [.macOS(.v14)], targets: [.target(name: "ToyUI")])
        """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let source = """
        import SwiftUI

        struct Fill: View {
            var body: some View {
                Color.blue.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        #Preview {
            Fill()
                .frame(width: 500, height: 300)
        }
        """
        let file = sources.appendingPathComponent("Fill.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)

        let swift = try XCTUnwrap(IDESwiftPMProjectSystem.resolveSwift(environment: nil))
        let session = makeSession(
            file: (file, source), package: (package, "ToyUI"),
            toolchain: .beside(swift: swift), runner: IDESwiftUIPreviewSubprocessRunner()
        )
        session.setViewport(CGSize(width: 640, height: 900))
        session.refresh()
        let ready = await waitUntil(seconds: 240) { session.phase == .ready && session.frame != nil }
        XCTAssertTrue(ready, "phase \(session.phase)\n\(session.log.suffix(20).joined(separator: "\n"))")
        XCTAssertTrue(session.previewHasOuterFrame)

        /// Whether the point (in points of the frame) is blue, not clear.
        func isBlue(x: Double, y: Double) -> Bool? {
            guard let data = session.frame?.tiffRepresentation, let rep = NSBitmapImageRep(data: data),
                  session.frameSize.width > 0 else { return nil }
            let pixelsPerPoint = Double(rep.pixelsWide) / Double(session.frameSize.width)
            guard let colour = rep.colorAt(x: Int(x * pixelsPerPoint), y: Int(y * pixelsPerPoint))?.usingColorSpace(.sRGB)
            else { return nil }
            return colour.alphaComponent > 0.9 && colour.blueComponent > 0.8 && colour.redComponent < 0.4
        }
        func waitFor(_ condition: @MainActor () -> Bool) async -> Bool { await waitUntil(seconds: 60, condition) }

        // A phone with a 59 pt top and a 34 pt bottom safe area (the iPhone 16): 393 × 852.
        let device = try XCTUnwrap(IDESwiftUIPreviewDevice.all.first { $0.id == "iphone-16" })
        XCTAssertEqual(device.safeTop, 59)
        session.setSizePreset(.device(device))
        let adapted = await waitFor {
            session.phase == .ready && session.ignoredFrame != nil && session.frameSize == CGSize(width: 393, height: 852)
                && isBlue(x: 196, y: 600) == true
        }
        XCTAssertTrue(adapted, "phase \(session.phase) ignored \(String(describing: session.ignoredFrame)) size \(session.frameSize)")
        XCTAssertEqual(session.ignoredFrame, ".frame(width: 500, height: 300)")
        // The content fills the screen between the safe areas and not the status bar or home indicator.
        XCTAssertEqual(isBlue(x: 196, y: 400), true)
        XCTAssertEqual(isBlue(x: 196, y: 30), false, "the status bar area is clear")
        XCTAssertEqual(isBlue(x: 196, y: 840), false, "the home indicator area is clear")

        // Keep the preview's own frame: 500 × 300 in the safe area, so a point far below it is clear.
        session.setKeepsPreviewFrame(true)
        let kept = await waitFor {
            session.phase == .ready && session.ignoredFrame == nil && isBlue(x: 196, y: 700) == false
        }
        XCTAssertTrue(kept, "phase \(session.phase) ignored \(String(describing: session.ignoredFrame))")
        XCTAssertEqual(isBlue(x: 196, y: 440), true, "the 300 pt frame is in the middle of the safe area")
        session.stop()
    }
}
