import Foundation
import JavaIntelligence
import SubprocessKit
import SwiftIntelligence

/// Run with Coverage (and later Profile) for an Xcode project.
///
/// Coverage is a test run with `-enableCodeCoverage YES` and then `xcrun xccov view` on the
/// bundle the run kept on `lastResultBundle` (`XCCovArchiveParser` reads the archive into the
/// report model the Coverage tab and the editor bands already draw).
extension IDEXcodeRunProvider {
    // MARK: - Entry points

    /// Run ▸ Run with Coverage / Profile: what the caret is in, else the project's tests or app.
    func runInstrumented(_ instrumentation: JavaRunInstrumentation, document: IDERunDocument?) -> Bool {
        switch instrumentation {
        case .coverage:
            if case .tests(let target)? = context(for: document?.url) {
                runTests(title: target, filters: [target], coverage: true)
            } else {
                runAllTestsWithCoverage()
            }
            return true
        case .profile:
            // Profile lands after coverage (results → coverage → profile): the build exists, the
            // recording does not yet.
            workspace?.reportRunProblem("Profiling Xcode projects is not available yet.")
            return true
        case .none:
            return false
        }
    }

    // MARK: - Gutter

    func supportsInstrumentation(at location: IDERunnableLocation) -> Bool {
        switch location.kind {
        case .test, .testGroup: true
        case .entryPoint, .preview: false
        }
    }

    func run(
        _ document: IDERunDocument, location: IDERunnableLocation,
        instrumentation: JavaRunInstrumentation
    ) {
        switch (location.kind, instrumentation) {
        case (.test, .coverage), (.testGroup, .coverage):
            runTests(title: location.title, filters: [testFilter(for: location, in: document)], coverage: true)
        case (.test, .profile), (.testGroup, .profile), (.entryPoint, _):
            workspace?.reportRunProblem("Profile a program, not its tests.")
        default:
            break
        }
    }

    /// Run ▸ Run All Tests with Coverage / Profile All Tests: the active test target, else every test.
    func runTestsInstrumented(_ instrumentation: JavaRunInstrumentation, document: IDERunDocument?) -> Bool {
        switch instrumentation {
        case .coverage:
            if case .tests(let target)? = context(for: document?.url) {
                runTests(title: target, filters: [target], coverage: true)
            } else {
                runAllTestsWithCoverage()
            }
            return true
        case .profile:
            workspace?.reportRunProblem("Profile a program, not its tests.")
            return true
        case .none:
            return false
        }
    }

    private func runAllTestsWithCoverage() {
        guard let model = xcode.model else { return }
        let targets = model.targets.filter { $0.kind == .test }.map(\.name)
        guard !targets.isEmpty else {
            workspace?.reportRunProblem("This project has no test target.")
            return
        }
        runTests(title: "all tests", filters: targets, coverage: true)
    }

    // MARK: - After a coverage run

    /// Reads the `xccov` report of the bundle a finished coverage run kept, and publishes it.
    func collectCoverage(label: String) {
        guard let workspace, let root = xcode.rootURL, let bundle = lastResultBundle else { return }
        workspace.coverage.beginReport(message: "Building the coverage report for “\(label)”…")
        workspace.showCoverageTabIfWanted()
        let environment = xcode.launchEnvironment
        let includeTests = IDEPreferences.shared.javaCoverageIncludesTests
        let startedAt = Date()
        Task { @MainActor [weak self] in
            @MainActor func fail(_ message: String) {
                guard let workspace = self?.workspace else { return }
                workspace.coverage.fail(message)
                workspace.showCoverageTabIfWanted()
                workspace.notifications.post("Coverage failed", detail: message, category: .general, severity: .error, action: .showCoverage)
            }
            guard let archive = await self?.xccov(bundle: bundle, kind: "archive", environment: environment),
                  let report = await self?.xccov(bundle: bundle, kind: "report", environment: environment)
            else {
                return fail("xccov did not answer; see the Xcode console.")
            }
            let options = LLVMCoverageJSONParser.Options(projectRoot: root, includeTests: includeTests)
            let parsed = await Task.detached(priority: .userInitiated) { () -> Result<JavaCoverageReport, Error> in
                Result {
                    try XCCovArchiveParser.parse(archive: archive, report: report, name: label, options: options)
                }
            }.value
            guard let workspace = self?.workspace else { return }
            switch parsed {
            case .failure(let error):
                fail(error.localizedDescription)
            case .success(let result):
                var stale = Set<String>()
                // A buffer with unsaved edits is not the text that was compiled and run.
                for file in result.sourceFiles {
                    guard let url = file.url, let buffer = workspace.openBufferText(for: url) else { continue }
                    if (try? String(contentsOf: url, encoding: .utf8)) != buffer { stale.insert(url.standardizedFileURL.path) }
                }
                workspace.coverage.publish(IDECoverageSnapshot(
                    report: result, runID: UUID().uuidString, label: label, date: startedAt,
                    tasks: ["xcodebuild test -enableCodeCoverage YES"], runDirectory: bundle,
                    executionFiles: [], classDirectories: [], sourceDirectories: [root], java: nil, cliJar: nil
                ), staleFiles: stale)
                workspace.refreshCoverageBands()
                workspace.showCoverageTabIfWanted()
                let percent = result.totals.lines.percent.map { "\($0)% of lines" } ?? "no executable lines"
                workspace.notifications.post(
                    "Coverage for “\(label)”", detail: percent, category: .general, severity: .success, action: .showCoverage
                )
            }
        }
    }

    /// `xcrun xccov view --<kind> --json <bundle>`. Off the main actor's path.
    func xccov(bundle: URL, kind: String, environment: [String: String]?) async -> Data? {
        guard let xcrun = Self.resolveXcrun(environment: environment) else { return nil }
        var request = SubprocessRequest(
            executable: xcrun, arguments: ["xccov", "view", "--\(kind)", "--json", bundle.path]
        )
        request.workingDirectory = xcode.rootURL ?? bundle.deletingLastPathComponent()
        request.environment = environment ?? ProcessInfo.processInfo.environment
        request.timeout = .seconds(120)
        guard let result = try? await SubprocessRunner.run(request) else { return nil }
        return result.stdout.text.data(using: .utf8)
    }
}
