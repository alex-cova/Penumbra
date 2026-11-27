import AppKit
import Foundation
import JavaIntelligence

extension IDEJavaRunProvider {
    func runGradleTestInvocation(
        root: URL, tasks: [String], arguments: [String], debug: Bool = false,
        configuration: JavaRunConfiguration? = nil, plan: InstrumentationPlan? = nil,
        original: UUID? = nil, replay: GradleLaunchSnapshot? = nil
    ) async -> IDEGradleRunOutcome {
        guard let host, gradle.rootURL == root, !gradle.isBusy else { return .notStarted("Gradle is busy.") }
        let presentation = host.testResults.gradle
        let history = GradleTestHistory.shared
        let epoch = launchEpoch
        let summary: GradleTestHistory.Summary
        do {
            summary = try await history.begin(root: root, tasks: tasks, original: original)
        } catch {
            let reason = "Could not create the Gradle test session. \(error.localizedDescription)"
            host.testResults.stopRun(message: reason)
            host.reportRunProblem(reason)
            return .notStarted(reason)
        }
        let session = GradleTestSession(id: summary.id, directory: history.directory(for: summary.id))
        let preferences = IDEPreferences.shared
        let days = min(365, max(1, preferences.gradleTestHistoryDays))
        let bytes = Int64(min(500, max(1, preferences.gradleTestHistoryGiB))) * 1024 * 1024 * 1024

        guard gradle.rootURL == root, launchEpoch == epoch, !gradle.isBusy else {
            let reason = "The Gradle test launch was cancelled before it started."
            try? await history.finish(summary, state: .cancelled, exitCode: nil, message: reason, days: days, bytes: bytes)
            return .notStarted(reason)
        }
        presentation.begin(summary)
        host.showTestResults()
        if let plan {
            pendingInstrumentation = (plan, tasks)
            instrumentationTestSessionID = summary.id
            if case .profile(let profile) = plan { beginLiveProfile(profile, processID: nil) }
        }

        let byTask = reportDirectories(for: tasks, root: root)
        let canonicalRoot = GradleBuildIdentity.canonicalPath(root)
        var reportSnapshot: GradleTestReports?
        var observedTasks: Set<String> = []
        var discoveredHTML: [String: URL] = [:]
        func observe(_ update: GradleTestSession.Update) {
            for node in update.nodes where node.event.build == canonicalRoot {
                guard let task = node.event.task else { continue }
                if node.isTest { observedTasks.insert(task) }
                if node.event.kind == .taskFinished, let path = node.event.report {
                    discoveredHTML[task] = URL(fileURLWithPath: path)
                }
            }
            presentation.ingest(update, for: summary.id)
        }

        let workingDirectory: URL? = configuration?.workingDirectory.flatMap { path -> URL? in
            guard !path.isEmpty else { return nil }
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path).standardizedFileURL
        }
        var didSettle = false
        let execution = IDEGradleProjectSystem.TestExecution(
            session: session,
            environment: configuration?.environment ?? [:],
            javaHome: configuration?.jdkHome.map { URL(fileURLWithPath: $0) },
            workingDirectory: workingDirectory,
            beforeLaunch: configuration?.beforeLaunch ?? [],
            instrumentation: configuration?.instrumentation ?? .none,
            canReplay: !debug && plan == nil && (configuration?.beforeLaunch.isEmpty ?? true),
            replay: replay,
            willLaunch: {
                reportSnapshot = await Task.detached {
                    GradleTestReports(directoriesByTask: byTask)
                }.value
            },
            update: observe,
            settle: { outcome, update in
                didSettle = true
                observe(update)
                let result = Self.testOutcome(outcome)
                let started = reportSnapshot?.started ?? summary.started
                let snapshot = reportSnapshot
                let liveTasks = observedTasks
                let html = discoveredHTML
                let activity = result.command?.streamedDiagnostics?.reportProducingTasks ?? []
                let saved = await Task.detached {
                    let reports = IDEGradleTestPresentation.SavedReports(
                        rows: result.state == .finished ? snapshot?.reconcile(excluding: liveTasks, didRun: activity) ?? [] : [],
                        html: html.compactMap { task, path in
                            guard liveTasks.contains(task) else { return nil }
                            return GradleTestReports.HTMLReport(task: task, url: path, since: started)
                        }
                    )
                    if let data = try? JSONEncoder().encode(reports) {
                        try? data.write(to: session.directory.appendingPathComponent("reports.json"), options: .atomic)
                    }
                    return reports
                }.value
                var finished = summary
                finished.state = result.state
                finished.exitCode = result.command?.exitCode
                finished.finishedAt = Date()
                var message = result.message
                if result.state == .finished, update.counts.values.reduce(0, +) == 0, saved.rows.isEmpty {
                    message += " · No current test results"
                } else if !saved.rows.isEmpty {
                    message += " · Includes Gradle XML reports"
                }
                finished.message = message
                do {
                    try await history.finish(summary, state: finished.state, exitCode: finished.exitCode,
                                             message: message, days: days, bytes: bytes)
                } catch {
                    finished.message = message + " · History could not be updated"
                }
                guard self.gradle.rootURL == root, presentation.summary?.id == summary.id else { return }
                presentation.finish(finished, reports: saved)
                host.testResults.stopRun(message: finished.message ?? message)
                await presentation.refreshHistory(root: root)
            }
        )
        let outcome = await withCheckedContinuation { continuation in
            gradle.runGradleTasks(tasks, extraArguments: arguments, runsApplication: debug, test: execution) {
                continuation.resume(returning: $0)
            }
        }
        if !didSettle { await execution.settle(outcome, session.seal(unfinished: .unknown)) }
        if instrumentationTestSessionID == summary.id {
            pendingInstrumentation = nil
            instrumentationTestSessionID = nil
        }
        return outcome
    }

    private static func testOutcome(_ outcome: IDEGradleRunOutcome) -> (state: GradleTestHistory.State, command: GradleCommandResult?, message: String) {
        switch outcome {
        case .finished(let command):
            return (.finished, command, command.exitCode == 0 ? "Gradle finished" : "Gradle exited \(command.exitCode)")
        case .cancelled(let partial): return (.cancelled, partial, "Gradle test run cancelled")
        case .timedOut(let partial): return (.failed, partial, "Gradle test run timed out")
        case .notStarted(let reason), .failed(let reason): return (.failed, nil, reason)
        }
    }

    private func reportDirectories(for tasks: [String], root: URL) -> [String: [URL]] {
        var reports: [String: [URL]] = [:]
        let model = gradle.model
        for task in tasks where !task.hasPrefix("-") {
            if !task.hasPrefix(":") {
                guard let model else { continue }
                for module in model.subprojects {
                    let prefix = module.path == ":" ? "" : module.path
                    let qualified = prefix + ":" + task
                    let directories = JavaTestRunner.reportDirectories(forQualifiedTaskPath: qualified, model: model)
                    if !directories.isEmpty { reports[qualified] = directories }
                }
                continue
            }
            if let model {
                let directories = JavaTestRunner.reportDirectories(forQualifiedTaskPath: task, model: model)
                if !directories.isEmpty { reports[task] = directories }
            } else if task == ":test" {
                reports[task] = [root.appendingPathComponent("build/test-results/test")]
            }
        }
        return reports
    }
}
