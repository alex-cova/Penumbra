import AppKit
import JavaIntelligence

extension IDEJavaRunProvider {
    enum GradleRetryScope {
        case complete, failed, selection
    }

    func retryGradleTests(_ scope: GradleRetryScope) {
        guard let host, let summary = host.testResults.gradle.summary,
              summary.state != .running, gradle.rootURL == summary.root,
              !gradle.isBusy, !gradleTestLaunchPending else { return }

        gradleTestLaunchPending = true
        let epoch = launchEpoch
        let presentation = host.testResults.gradle
        Task { [weak self] in
            guard let self else { return }
            defer { self.gradleTestLaunchPending = false }
            let recipe: GradleLaunchSnapshot
            do {
                recipe = try await Self.verifiedLaunch(summary)
            } catch {
                presentation.showActionMessage("Exact replay is unavailable. \(error.localizedDescription)")
                return
            }
            guard GradleTestRetryPlan.supportsTaskRerun(recipe.gradleVersion) else {
                presentation.showActionMessage("Task-scoped rerun has not been verified for Gradle \(recipe.gradleVersion ?? "in this launch").")
                return
            }

            let invocations: [GradleTestRetryPlan.Invocation]
            switch scope {
            case .complete:
                guard let invocation = GradleTestRetryPlan.complete(tasks: recipe.tasks, arguments: recipe.arguments) else {
                    presentation.showActionMessage("The original test task graph could not be verified.")
                    return
                }
                invocations = [invocation]
            case .failed, .selection:
                let candidates = scope == .failed ? presentation.failedTests() : presentation.selectedTests()
                guard !candidates.isEmpty else {
                    presentation.showActionMessage("Select tests with a verified Gradle invocation to retry.")
                    return
                }
                let classes = await java.allTestClasses()
                let resolution = Self.retryTargets(candidates, classes: classes, root: summary.root)
                guard resolution.unavailable == 0, !resolution.targets.isEmpty else {
                    presentation.showActionMessage("\(resolution.unavailable) selected tests have no verified task and selector.")
                    return
                }
                if !resolution.broadened.isEmpty,
                   !(await Self.confirmBroaderRetry(filters: resolution.broadened)) { return }
                invocations = GradleTestRetryPlan.granular(targets: resolution.targets, arguments: recipe.arguments)
            }

            for invocation in invocations {
                guard launchEpoch == epoch, gradle.rootURL == summary.root else { return }
                let outcome = await runGradleTestInvocation(
                    root: summary.root, tasks: invocation.tasks, arguments: invocation.arguments,
                    original: summary.original ?? summary.id, replay: recipe
                )
                switch outcome {
                case .finished: continue
                case .notStarted, .failed, .cancelled, .timedOut: return
                }
            }
        }
    }

    @concurrent private static func verifiedLaunch(_ summary: GradleTestHistory.Summary) async throws -> GradleLaunchSnapshot {
        let recipe = try GradleLaunchSnapshot.load(from: GradleTestHistory.shared.directory(for: summary.id))
        try recipe.validate(root: summary.root)
        return recipe
    }

    private static func retryTargets(
        _ candidates: [GradleTestSession.Node], classes: [JavaTestClass], root: URL
    ) -> (targets: Set<GradleTestRetryPlan.Target>, broadened: Set<String>, unavailable: Int) {
        var targets: Set<GradleTestRetryPlan.Target> = []
        var broadened: Set<String> = []
        var unavailable = 0
        let rootPath = GradleBuildIdentity.canonicalPath(root)
        for test in candidates {
            let event = test.event
            guard event.build == rootPath, let task = event.task, task.hasPrefix(":"),
                  let className = event.className, !className.contains("*"),
                  let declaration = classes.first(where: {
                      $0.gradleTaskPath == task && ($0.qualifiedName == className || $0.methods.contains { $0.className == className })
                  }) else {
                unavailable += 1
                continue
            }
            let publishedMethod = event.methodName ?? event.name
            var filter = className
            var scopeIsBroader = true
            if let name = publishedMethod,
               let method = declaration.methods.first(where: { $0.className == className && $0.methodName == name }) {
                filter = method.gradleTestFilter(includeMethod: true)
                // A method selector can also select parameterized or repeated invocations.
                // Require confirmation except for the verified plain JUnit 4 case.
                scopeIsBroader = method.framework != .junit4 || event.name != name
            }
            if scopeIsBroader { broadened.insert(filter) }
            targets.insert(.init(task: task, filter: filter))
        }
        return (targets, broadened, unavailable)
    }

    private static func confirmBroaderRetry(filters: Set<String>) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Run the matching method or class?"
        let preview = filters.sorted().prefix(4).joined(separator: "\n")
        let remaining = filters.count > 4 ? "\n…and \(filters.count - 4) more" : ""
        alert.informativeText = "Gradle may run additional invocations for these filters.\n\n" + preview + remaining
        alert.addButton(withTitle: "Run Tests")
        alert.addButton(withTitle: "Cancel")
        if let window = NSApp.keyWindow {
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
