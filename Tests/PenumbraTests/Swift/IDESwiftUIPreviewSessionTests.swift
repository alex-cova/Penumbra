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
        trusted: Bool = true,
        toolchain: IDESwiftUIPreviewToolchain? = IDESwiftUIPreviewToolchain(swift: "/usr/bin/swift", swiftc: "/usr/bin/swiftc"),
        runner: any IDESwiftUIPreviewProcessRunning,
        published: @escaping @MainActor ([URL: [Diagnostic]]) -> Void = { _ in }
    ) -> IDESwiftUIPreviewSession {
        let context = IDESwiftUIPreviewContext(
            activeFile: { fileProvider?() ?? file },
            package: { _ in package },
            ensureTrusted: { trusted },
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
}
