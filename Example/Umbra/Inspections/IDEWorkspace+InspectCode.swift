import AppKit
import EditorIntelligence
import Foundation
import JavaIntelligence

/// What an Inspect Code run was asked: kept with the run so Rerun repeats it.
struct IDEInspectionLaunch {
    var scope: JavaInspectionScope
    var profile: JavaInspectionProfile
    var profileName: String
    var onlyRules: Set<JavaInspectionRule>?
    var includeProjectRules: Bool
}

/// A request to ask the user for a scope (Inspect Code…) or a rule and then a scope.
struct IDEInspectCodeRequest: Identifiable {
    let id = UUID()
    /// Set by Run Inspection by Name once a rule was picked.
    var rule: JavaInspectionRule?
    /// Files to offer as "Selected files" (the Explorer's selection) or "Current file".
    var selectedFiles: [URL] = []
    var currentFile: URL?
    var directory: URL?
}

extension IDEWorkspace {
    // MARK: - Presenting

    /// Code ▸ Inspect Code…: asks which files, then analyses them.
    func presentInspectCode(selectedFiles: [URL] = [], directory: URL? = nil) {
        inspectionRuns.pendingScopeRequest = IDEInspectCodeRequest(
            selectedFiles: selectedFiles, currentFile: activeJavaFile, directory: directory
        )
    }

    /// Code ▸ Run Inspection by Name…: pick a rule, then the scope.
    func presentRunInspectionByName(rule: JavaInspectionRule? = nil) {
        if let rule {
            inspectionRuns.pendingScopeRequest = IDEInspectCodeRequest(rule: rule, currentFile: activeJavaFile)
        } else {
            inspectionRuns.isNamePickerPresented = true
        }
    }

    /// Explorer ▸ Inspect Code… on a file or a folder.
    func inspectCode(forExplorerItem url: URL) {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            presentInspectCode(directory: url)
        } else {
            presentInspectCode(selectedFiles: [url])
        }
    }

    /// The editor's right-click ▸ Inspect Code… for a Java file.
    func inspectionContextMenuItems(url: URL?) -> [NSMenuItem] {
        guard let url, url.pathExtension.lowercased() == "java" else { return [] }
        return [IDEClosureMenuItem(title: "Inspect Code…") { [weak self] in
            self?.presentInspectCode(selectedFiles: [url])
        }]
    }

    private var activeJavaFile: URL? {
        guard let url = workbench.activePane.selectedDocument?.url, url.pathExtension == "java" else { return nil }
        return url
    }

    // MARK: - Running

    /// Starts a run and shows its tab.
    @discardableResult
    func startInspection(_ launch: IDEInspectionLaunch) -> IDEInspectionRun {
        let run = IDEInspectionRun(
            scope: launch.scope, onlyRules: launch.onlyRules, includeProjectRules: launch.includeProjectRules,
            profileName: launch.profileName
        )
        run.launch = launch
        inspectionRuns.add(run)
        showProblems()
        beginInspection(run)
        return run
    }

    func rerunInspection(_ run: IDEInspectionRun) {
        guard run.state != .running, run.launch != nil else { return }
        beginInspection(run)
    }

    private func beginInspection(_ run: IDEInspectionRun) {
        guard let launch = run.launch else { return }
        run.begin(total: 0)
        let root = project.rootURL
        let classifier = JavaInspectionFileClassifier(projectRoot: root, testRoots: javaTestSourceRoots)
        let inspector = javaSupport.makeBatchInspector()
        let options = JavaBatchInspector.Options(
            profile: launch.profile, classifier: classifier, onlyRules: launch.onlyRules,
            includeProjectRules: launch.includeProjectRules
        )
        run.task = Task { [weak self, weak run] in
            let scope = launch.scope
            let files = await Task.detached(priority: .userInitiated) {
                scope.resolve(projectRoots: root.map { [$0] } ?? [], classifier: classifier)
            }.value
            guard let self, let run else { return }
            let text = self.inspectionTextSource()
            for await event in inspector.run(files: files, options: options, text: text) {
                switch event {
                case .started(let total): run.progress(done: 0, total: total)
                case .file(let url, let findings): run.record(findings, for: url)
                case .progress(let done, let total): run.progress(done: done, total: total)
                case .finished(let cancelled): run.finish(cancelled: cancelled)
                }
            }
            if run.state == .running { run.finish(cancelled: Task.isCancelled) }
        }
    }

    /// A file's text for analysis: the open buffer first, else the disk.
    func inspectionTextSource() -> @Sendable (URL) async -> String? {
        { [weak self] url in
            if let self, let open = await MainActor.run(body: { self.openBufferText(for: url) }) { return open }
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    // MARK: - Fixing

    /// The fixes and Suppress actions for one result, from the file's current text.
    func quickFixes(for entry: IDEInspectionRun.Entry) async -> [CodeAction] {
        guard let text = await inspectionTextSource()(entry.url) else { return [] }
        let style: JavaSuppressionStyle = preferences.javaSuppressWithComment ? .comment : .annotation
        return JavaInspectionQuickFixes.actions(for: entry.inspection, in: text, suppressionStyle: style)
    }

    /// The fixes and Suppress actions for a Problems row from an inspection.
    func quickFixes(for row: ProblemRow) async -> [CodeAction] {
        guard row.diagnostic.source == "java-inspection", let text = await inspectionTextSource()(row.url) else { return [] }
        let style: JavaSuppressionStyle = preferences.javaSuppressWithComment ? .comment : .annotation
        return JavaInspectionQuickFixes.actions(for: row.diagnostic, in: text, suppressionStyle: style)
    }

    /// Applies a fix chosen for a Problems row.
    func applyQuickFix(_ action: CodeAction, to url: URL) async {
        guard !action.edits.isEmpty else { return }
        let result = await historyRecordingApplier(named: "Quick Fix").apply(WorkspaceEdit(changes: [url: action.edits]))
        if let message = result.failures.values.first {
            notifications.post("Could not apply the fix", detail: message, category: .general, severity: .error)
        }
    }

    /// Shows fixes (then Suppress actions) as a menu at the pointer.
    func popUpQuickFixMenu(_ actions: [CodeAction], apply: @escaping (CodeAction) -> Void) {
        let menu = NSMenu()
        func item(for action: CodeAction) -> NSMenuItem {
            let handler = IDEMenuClosure { apply(action) }
            let item = NSMenuItem(title: action.title, action: #selector(IDEMenuClosure.fire), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler
            return item
        }
        let fixes = actions.filter { !$0.title.hasPrefix("Suppress") }
        let suppress = actions.filter { $0.title.hasPrefix("Suppress") }
        for action in fixes { menu.addItem(item(for: action)) }
        if !suppress.isEmpty {
            if !fixes.isEmpty { menu.addItem(.separator()) }
            for action in suppress { menu.addItem(item(for: action)) }
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "No quick fixes available", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Applies one fix of a result and re-inspects its file; the result turns "resolved".
    func applyInspectionFix(_ action: CodeAction, to entry: IDEInspectionRun.Entry, in run: IDEInspectionRun) async {
        guard !action.edits.isEmpty else { return }
        let result = await historyRecordingApplier(named: "Inspection Fix").apply(WorkspaceEdit(changes: [entry.url: action.edits]))
        guard result.failures.isEmpty else {
            notifications.post("Could not apply the fix", detail: result.failures.values.first, category: .general, severity: .error)
            return
        }
        await reinspect([entry.url], in: run, handled: [entry])
    }

    /// Applies the preferred fix of every result of `rule` in the run (or only `urls`).
    func applyInspectionFixAll(rule: JavaInspectionRule, in run: IDEInspectionRun, urls: Set<URL>? = nil) async {
        let entries = run.entries.filter {
            $0.inspection.id == rule.code && !run.excludedKeys.contains($0.key) && (urls?.contains($0.url) ?? true)
        }
        guard !entries.isEmpty else { return }
        let touched = Array(Set(entries.map(\.url)))
        let outcome = await fixAll(rules: [rule], in: touched)
        guard outcome.fixedCount > 0 else {
            notifications.post("Nothing to fix", detail: "'\(rule.title)' has no automatic fix for these results.", category: .general)
            return
        }
        await reinspect(touched, in: run, handled: entries)
        notifications.post(
            "Fixed \(outcome.fixedCount) problem\(outcome.fixedCount == 1 ? "" : "s") in \(outcome.fileCount) file\(outcome.fileCount == 1 ? "" : "s")",
            detail: rule.title, category: .general, action: .showProblems
        )
    }

    /// Fixes every finding of `rules` in `files` (Run Inspection by Name ▸ Fix All) as one action.
    func fixAll(rules: Set<JavaInspectionRule>, in files: [URL]) async -> (fixedCount: Int, fileCount: Int) {
        let index = javaSupport.javaIndex
        let source = inspectionTextSource()
        var changes: [URL: [TextEdit]] = [:]
        var fixed = 0
        for url in files {
            if Task.isCancelled { break }
            guard let text = await source(url) else { continue }
            let result = await JavaBatchFixer.fixAll(rules: rules, in: text, url: url, index: index)
            guard !result.isEmpty, !result.edits.isEmpty else { continue }
            changes[url] = result.edits
            fixed += result.fixedCount
        }
        guard !changes.isEmpty else { return (0, 0) }
        let result = await historyRecordingApplier(named: "Inspection Fix All").apply(WorkspaceEdit(changes: changes))
        for (url, message) in result.failures {
            notifications.post("Could not fix \(url.lastPathComponent)", detail: message, category: .general, severity: .error)
        }
        return (fixed, result.appliedFiles.count)
    }

    private func reinspect(_ urls: [URL], in run: IDEInspectionRun, handled: [IDEInspectionRun.Entry]) async {
        guard let launch = run.launch else { return }
        let inspector = javaSupport.makeBatchInspector()
        let options = JavaBatchInspector.Options(
            profile: launch.profile,
            classifier: JavaInspectionFileClassifier(projectRoot: project.rootURL, testRoots: javaTestSourceRoots),
            onlyRules: launch.onlyRules, includeProjectRules: launch.includeProjectRules
        )
        let text = inspectionTextSource()
        for url in urls {
            let fresh = await inspector.inspect(url: url, options: options, text: text)
            run.markResolved(handled.filter { $0.url == url }, newFindings: fresh, for: url)
        }
    }

    // MARK: - Result actions

    func openInspectionResult(_ entry: IDEInspectionRun.Entry) {
        openProblem(ProblemRow(url: entry.url, diagnostic: entry.inspection.asDiagnostic()))
    }

    /// Disables the rule in the active profile and drops its results from the run.
    func disableInspection(_ rule: JavaInspectionRule) {
        inspections.edit { $0.setEnabled(false, for: rule) }
    }

    // MARK: - Commit check

    /// Inspects staged files with the active profile (no project-wide rules) and counts what a
    /// reader would call a problem: errors and warnings.
    func analyzeForCommit(_ files: [URL]) async -> IDEGitCommitFacts.CodeAnalysis {
        let inspector = javaSupport.makeBatchInspector()
        let options = JavaBatchInspector.Options(
            profile: inspections.activeProfile,
            classifier: JavaInspectionFileClassifier(projectRoot: project.rootURL, testRoots: javaTestSourceRoots)
        )
        let text = inspectionTextSource()
        var analysis = IDEGitCommitFacts.CodeAnalysis()
        let root = project.rootURL?.standardizedFileURL.path
        for url in files {
            let findings = await inspector.inspect(url: url, options: options, text: text)
            let errors = findings.filter { $0.severity == .error }.count
            let warnings = findings.filter { $0.severity == .warning }.count
            guard errors + warnings > 0 else { continue }
            analysis.errors += errors
            analysis.warnings += warnings
            let path = url.standardizedFileURL.path
            analysis.paths.append(root.flatMap { path.hasPrefix($0 + "/") ? String(path.dropFirst($0.count + 1)) : nil } ?? path)
        }
        return analysis
    }

    /// "Review Problems" in the commit check: the findings of those files in a Problems tab.
    func reviewCommitAnalysis(relativePaths: [String]) {
        guard let root = project.rootURL else { return }
        let urls = relativePaths.map { URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL }
        startInspection(IDEInspectionLaunch(
            scope: JavaInspectionScope(kind: .files(urls)), profile: inspections.activeProfile,
            profileName: inspections.title(for: inspections.activeSource), onlyRules: nil, includeProjectRules: false
        ))
    }

    // MARK: - Exporting

    func exportInspectionRun(_ run: IDEInspectionRun, as format: IDEInspectionExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "inspection-results.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let report = JavaInspectionReport(title: run.title, results: run.results, root: project.rootURL)
        let data = format == .sarif ? report.sarif() : Data(report.html().utf8)
        do {
            try data.write(to: url, options: .atomic)
            notifications.post("Exported inspection results", detail: url.lastPathComponent, category: .general, action: .revealInFinder(url.path))
        } catch {
            notifications.post("Could not export results", detail: error.localizedDescription, category: .general, severity: .error)
        }
    }
}

enum IDEInspectionExportFormat {
    case sarif
    case html

    var fileExtension: String { self == .sarif ? "sarif" : "html" }
}
