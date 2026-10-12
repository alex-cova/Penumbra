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
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-preview-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
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
