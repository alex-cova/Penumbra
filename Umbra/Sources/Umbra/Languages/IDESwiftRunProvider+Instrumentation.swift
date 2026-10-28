import Foundation
import JavaIntelligence
import SubprocessKit
import SwiftIntelligence

/// Run Tests with Coverage and Profile for a SwiftPM package.
///
/// **Coverage** runs `swift test --enable-code-coverage`, asks SwiftPM where it left the `llvm-cov export` JSON and
/// reads it into the report the Coverage tab and the editor bands already show (`LLVMCoverageJSONParser`: a target
/// is a package, a file a class). **Profile** builds the program in release, records it with Instruments'
/// Time Profiler (`xcrun xctrace record --launch`), exports the `time-profile` table and opens it in the same
/// profiler tab Java uses (`XCTraceTimeProfileParser`). Both need the toolchain's own tools: `swift`, and for the
/// profile Xcode's `xctrace`.
extension IDESwiftRunProvider {
    /// Marks a Run-tab session as a profile run, so Rerun records again instead of just running.
    struct ProfilePayload {
        var name: String
    }

    // MARK: - Gutter

    func supportsInstrumentation(at location: IDERunnableLocation) -> Bool {
        switch location.kind {
        case .test, .testGroup, .entryPoint: true
        case .preview: false
        }
    }

    func run(_ document: IDERunDocument, location: IDERunnableLocation, instrumentation: JavaRunInstrumentation) {
        switch (location.kind, instrumentation) {
        case (.test, .coverage), (.testGroup, .coverage):
            runTests(title: location.title, filters: [testFilter(for: location, in: document)], coverage: true)
        case (.entryPoint, .profile):
            if case .executable(let name)? = context(for: document.url) { profileExecutable(name) }
        case (.entryPoint, .coverage):
            workspace?.reportRunProblem("Coverage is measured by running tests. Use a test's gutter menu or Run Tests with Coverage.")
        case (.test, .profile), (.testGroup, .profile):
            workspace?.reportRunProblem("Profile a program, not its tests: use the gutter menu of a program's entry point.")
        default:
            break
        }
    }

    // MARK: - Menu (Run ▸ Run with Coverage, Profile, … Tests)

    /// Run ▸ Run with Coverage / Profile for the active Swift file. `false` when there is nothing to run.
    func runInstrumented(_ instrumentation: JavaRunInstrumentation, document: IDERunDocument?) -> Bool {
        switch (context(for: document?.url), instrumentation) {
        case (.executable(let name)?, .profile):
            profileExecutable(name)
            return true
        case (.tests(let target)?, .coverage):
            runTests(title: target, filters: ["\(target)."], coverage: true)
            return true
        case (_, .coverage):
            return runAllTestsWithCoverage()
        default:
            return false
        }
    }

    /// Run ▸ Run Tests with Coverage: the active test target, else every test of the package.
    func runTestsInstrumented(_ instrumentation: JavaRunInstrumentation, document: IDERunDocument?) -> Bool {
        guard instrumentation == .coverage else {
            workspace?.reportRunProblem("Profile a program, not its tests.")
            return true
        }
        if case .tests(let target)? = context(for: document?.url) {
            runTests(title: target, filters: ["\(target)."], coverage: true)
            return true
        }
        return runAllTestsWithCoverage()
    }

    private func runAllTestsWithCoverage() -> Bool {
        guard swiftPM.isActive, let manifest = swiftPM.manifest else { return false }
        let targets = manifest.targets.filter { $0.kind == .test }.map(\.name)
        guard !targets.isEmpty else {
            workspace?.reportRunProblem("This package has no test target.")
            return true
        }
        runTests(title: "all tests", filters: targets.map { "\($0)." }, coverage: true)
        return true
    }

    // MARK: - After a coverage run

    /// Reads the coverage JSON a finished `swift test --enable-code-coverage` left, and publishes it.
    func collectCoverage(label: String) {
        guard let workspace, let root = swiftPM.rootURL else { return }
        workspace.coverage.beginReport(message: "Building the coverage report for “\(label)”…")
        workspace.showCoverageTabIfWanted()
        let environment = swiftPM.launchEnvironment
        let includeTests = IDEPreferences.shared.javaCoverageIncludesTests
        let startedAt = Date()
        Task { @MainActor [weak self] in
            @MainActor func fail(_ message: String) {
                guard let workspace = self?.workspace else { return }
                workspace.coverage.fail(message)
                workspace.showCoverageTabIfWanted()
                workspace.notifications.post("Coverage failed", detail: message, category: .general, severity: .error, action: .showCoverage)
            }
            guard let swift = IDESwiftPMProjectSystem.resolveSwift(environment: environment) else {
                return fail("No swift found on PATH.")
            }
            var request = SubprocessRequest(executable: swift, arguments: SwiftCoverageCommand.codecovPathArguments)
            request.workingDirectory = root
            request.environment = environment ?? ProcessInfo.processInfo.environment
            request.timeout = .seconds(120)
            request.stderrCapture = .bounded(head: 2_000, tail: 4_000)
            guard let result = try? await SubprocessRunner.run(request), result.exit.succeeded,
                  let path = SwiftCoverageCommand.codecovPath(fromOutput: result.stdout.text),
                  FileManager.default.fileExists(atPath: path.path) else {
                return fail("SwiftPM left no coverage data. A test run that did not build or never started has none; see the SwiftPM console.")
            }
            let options = LLVMCoverageJSONParser.Options(projectRoot: root, includeTests: includeTests)
            let parsed = await Task.detached(priority: .userInitiated) { () -> Result<JavaCoverageReport, Error> in
                Result {
                    try LLVMCoverageJSONParser.parse(Data(contentsOf: path), name: label, options: options)
                }
            }.value
            guard let workspace = self?.workspace else { return }
            switch parsed {
            case .failure(let error):
                fail(error.localizedDescription)
            case .success(let report):
                var stale = Set<String>()
                // A buffer with unsaved edits is not the text that was compiled and run.
                for file in report.sourceFiles {
                    guard let url = file.url, let buffer = workspace.openBufferText(for: url) else { continue }
                    if (try? String(contentsOf: url, encoding: .utf8)) != buffer { stale.insert(url.standardizedFileURL.path) }
                }
                workspace.coverage.publish(IDECoverageSnapshot(
                    report: report, runID: UUID().uuidString, label: label, date: startedAt,
                    tasks: ["swift test --enable-code-coverage"], runDirectory: path.deletingLastPathComponent(),
                    executionFiles: [], classDirectories: [], sourceDirectories: [root], java: nil, cliJar: nil
                ), staleFiles: stale)
                workspace.refreshCoverageBands()
                workspace.showCoverageTabIfWanted()
                let percent = report.totals.lines.percent.map { "\($0)% of lines" } ?? "no executable lines"
                workspace.notifications.post(
                    "Coverage for “\(label)”", detail: percent, category: .general, severity: .success, action: .showCoverage
                )
            }
        }
    }

    // MARK: - Profile

    /// Builds `name` in release and records one run of it with the Time Profiler.
    func profileExecutable(_ name: String) {
        guard let workspace else { return }
        if swiftPM.isRunningTasks {
            workspace.reportRunProblem("SwiftPM is busy; wait for it or stop it first.")
            return
        }
        let build = IDESwiftPMInvocation(
            title: "swift build -c release --product \(name)", arguments: ["build", "-c", "release", "--product", name]
        )
        let locate = IDESwiftPMInvocation(
            title: "swift build -c release --show-bin-path",
            arguments: ["build", "-c", "release", "--product", name, "--show-bin-path"], collectsDiagnostics: false
        )
        swiftPM.run([build, locate]) { [weak self] outcomes in
            guard let self, let workspace = self.workspace else { return }
            guard outcomes.count == 2, outcomes[0].succeeded, outcomes[1].succeeded,
                  let directory = Self.binDirectory(in: outcomes[1].output) else {
                workspace.reportRunProblem("The release build did not produce a program to profile.")
                return
            }
            let binary = URL(fileURLWithPath: directory).appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: binary.path) else {
                workspace.reportRunProblem("No executable at \(binary.path).")
                return
            }
            self.record(name: name, binary: binary)
        }
    }

    private func record(name: String, binary: URL) {
        guard let workspace, let root = swiftPM.rootURL else { return }
        let runID = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = Self.profileFolder(for: root).appendingPathComponent(runID, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let trace = folder.appendingPathComponent("\(name).trace")
        let environment = swiftPM.launchEnvironment ?? ProcessInfo.processInfo.environment
        _ = workspace.runs.start(IDERunRequest(
            id: UUID(), title: "Profile \(name)", providerID: id, payload: ProfilePayload(name: name), allowsMultipleInstances: false,
            prepare: { [weak self] session in
                let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
                guard FileManager.default.isExecutableFile(atPath: xcrun.path) else {
                    session.fail("xcrun was not found. Profiling Swift needs Xcode's command line tools (xctrace).")
                    return
                }
                session.onFinished = { [weak self] session in
                    if case .failed = session.state { return }
                    guard FileManager.default.fileExists(atPath: trace.path) else {
                        session.appendNote("No recording was written. Instruments needs the program to start and exit.")
                        return
                    }
                    self?.workspace?.openSwiftProfile(trace: trace, title: "Profile: \(name)", root: root)
                    Self.pruneProfiles(in: Self.profileFolder(for: root), keeping: folder.lastPathComponent)
                }
                session.start(IDEProcessLaunch(
                    executable: xcrun,
                    arguments: SwiftProfileCommand.recordArguments(trace: trace, executable: binary),
                    workingDirectory: root, environment: environment,
                    displayCommand: "xctrace record --template '\(SwiftProfileCommand.template)' --launch -- \(binary.lastPathComponent)"
                ))
            }
        ))
        workspace.showRunTab()
    }

    /// `Caches/com.umbra.editor/SwiftProfiles/<hash of the project>`.
    static func profileFolder(for root: URL) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let key = String(format: "%08x", abs(root.standardizedFileURL.path.hashValue) & 0xffff_ffff)
        return caches.appendingPathComponent("com.umbra.editor/SwiftProfiles/\(key)", isDirectory: true)
    }

    /// Keeps the newest ten runs of a project.
    static func pruneProfiles(in folder: URL, keeping current: String) {
        let runs = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in runs.dropFirst(10) where old.lastPathComponent != current { try? FileManager.default.removeItem(at: old) }
    }

    /// Exports a recording's `time-profile` table with `xctrace` and parses it. Off the main actor.
    nonisolated static func loadTimeProfile(trace: URL) async throws -> JavaProfile {
        let xml = trace.deletingPathExtension().appendingPathExtension("time-profile.xml")
        var request = SubprocessRequest(
            executable: "/usr/bin/xcrun", arguments: SwiftProfileCommand.exportArguments(trace: trace, output: xml)
        )
        request.timeout = .seconds(300)
        request.stderrCapture = .bounded(head: 2_000, tail: 4_000)
        let result = try await SubprocessRunner.run(request)
        guard result.exit.succeeded else {
            throw ExportFailure(message: "xctrace could not export the recording: \(result.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        defer { try? FileManager.default.removeItem(at: xml) }
        return try XCTraceTimeProfileParser.parse(contentsOf: xml)
    }

    struct ExportFailure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}
