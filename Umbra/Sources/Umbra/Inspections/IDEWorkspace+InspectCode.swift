import AppKit
import EditorIntelligence
import Foundation
import JavaIntelligence
import SwiftIntelligence

/// What an Inspect Code run was asked: kept with the run so Rerun repeats it.
struct IDEInspectionLaunch {
    /// What each language needs to run: Java's profile and project-wide rules, Swift's options.
    enum Backend {
        case java(scope: JavaInspectionScope, profile: JavaInspectionProfile, onlyRules: Set<JavaInspectionRule>?, includeProjectRules: Bool)
        /// `resolver` gives the options of one file when a profile's scopes make them differ; `options` is the base.
        case swift(
            scope: SwiftInspectionScope, options: SwiftInspectionOptions, onlyRules: Set<SwiftInspectionRule>?,
            resolver: (@Sendable (URL) -> SwiftInspectionOptions)?
        )
    }

    var backend: Backend
    var profileName: String

    init(backend: Backend, profileName: String) {
        self.backend = backend
        self.profileName = profileName
    }

    /// A Java run, which is what the workflow was first written for.
    init(
        scope: JavaInspectionScope, profile: JavaInspectionProfile, profileName: String,
        onlyRules: Set<JavaInspectionRule>?, includeProjectRules: Bool
    ) {
        self.init(
            backend: .java(scope: scope, profile: profile, onlyRules: onlyRules, includeProjectRules: includeProjectRules),
            profileName: profileName
        )
    }

    init(swiftScope: SwiftInspectionScope, options: SwiftInspectionOptions, onlyRules: Set<SwiftInspectionRule>?) {
        self.init(backend: .swift(scope: swiftScope, options: options, onlyRules: onlyRules, resolver: nil), profileName: "Swift settings")
    }

    /// A Swift run under a profile: each file gets the options its scopes give it.
    init(swiftScope: SwiftInspectionScope, profile: SwiftInspectionProfile, profileName: String, root: URL?, onlyRules: Set<SwiftInspectionRule>?) {
        let classifier = SwiftInspectionFileClassifier(projectRoot: root)
        self.init(
            backend: .swift(
                scope: swiftScope, options: profile.options(), onlyRules: onlyRules,
                resolver: { url in profile.options(for: classifier.context(for: url)) }
            ),
            profileName: profileName
        )
    }

    var language: IDEInspectionLanguage {
        switch backend {
        case .java: .java
        case .swift: .swift
        }
    }

    var scopeTitle: String {
        switch backend {
        case .java(let scope, _, _, _): scope.title
        case .swift(let scope, _, _, _): scope.title
        }
    }

    var onlyRuleCodes: Set<String>? {
        switch backend {
        case .java(_, _, let only, _): only.map { Set($0.map(\.code)) }
        case .swift(_, _, let only, _): only.map { Set($0.map(\.code)) }
        }
    }

    var includeProjectRules: Bool {
        if case .java(_, _, _, let include) = backend { return include }
        return false
    }
}

/// A request to ask the user for a scope (Inspect Code…) or a rule and then a scope.
struct IDEInspectCodeRequest: Identifiable {
    let id = UUID()
    /// The language the sheet starts on; it can be changed while no rule, file or selection fixes it.
    var language: IDEInspectionLanguage = .java
    /// Set by Run Inspection by Name once a rule was picked.
    var rule: IDEInspectionRuleInfo?
    /// Files to offer as "Selected files" (the Explorer's selection) or "Current file".
    var selectedFiles: [URL] = []
    var currentFile: URL?
    var directory: URL?

    /// Whether the language is part of what was asked, so the sheet does not offer the other one.
    var isLanguageFixed: Bool { rule != nil || !selectedFiles.isEmpty }
}

extension IDEWorkspace {
    // MARK: - Presenting

    /// Code ▸ Inspect Code…: asks which files, then analyses them.
    func presentInspectCode(language: IDEInspectionLanguage = .java, selectedFiles: [URL] = [], directory: URL? = nil) {
        inspectionRuns.pendingScopeRequest = IDEInspectCodeRequest(
            language: language, selectedFiles: selectedFiles, currentFile: activeFile(of: language), directory: directory
        )
    }

    /// Code ▸ Run Inspection by Name…: pick a rule, then the scope.
    func presentRunInspectionByName(language: IDEInspectionLanguage = .java, rule: IDEInspectionRuleInfo? = nil) {
        if let rule {
            inspectionRuns.pendingScopeRequest = IDEInspectCodeRequest(
                language: rule.language, rule: rule, currentFile: activeFile(of: rule.language)
            )
        } else {
            inspectionRuns.nameQueryLanguage = language
            inspectionRuns.isNamePickerPresented = true
        }
    }

    /// Explorer ▸ Inspect Code… on a file or a folder.
    func inspectCode(forExplorerItem url: URL) {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            // A folder may hold either language: start on the active file's.
            let language = Self.inspectionLanguage(of: workbench.activePane.selectedDocument?.url) ?? .java
            presentInspectCode(language: language, directory: url)
        } else if let language = Self.inspectionLanguage(of: url) {
            presentInspectCode(language: language, selectedFiles: [url])
        }
    }

    /// The editor's right-click ▸ Inspect Code… for a Java or Swift file.
    func inspectionContextMenuItems(url: URL?) -> [NSMenuItem] {
        guard let url, let language = Self.inspectionLanguage(of: url) else { return [] }
        return [IDEClosureMenuItem(title: "Inspect Code…") { [weak self] in
            self?.presentInspectCode(language: language, selectedFiles: [url])
        }]
    }

    /// The language Inspect Code has for a file, by its extension.
    static func inspectionLanguage(of url: URL?) -> IDEInspectionLanguage? {
        url.flatMap { IDEInspectionLanguage(rawValue: $0.pathExtension.lowercased()) }
    }

    private func activeFile(of language: IDEInspectionLanguage) -> URL? {
        guard let url = workbench.activePane.selectedDocument?.url, Self.inspectionLanguage(of: url) == language else { return nil }
        return url
    }

    // MARK: - Running

    /// Starts a run and shows its tab.
    @discardableResult
    func startInspection(_ launch: IDEInspectionLaunch) -> IDEInspectionRun {
        let run = IDEInspectionRun(
            language: launch.language, scopeTitle: launch.scopeTitle, onlyRuleCodes: launch.onlyRuleCodes,
            includeProjectRules: launch.includeProjectRules, profileName: launch.profileName
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
        switch launch.backend {
        case .java(let scope, let profile, let onlyRules, let includeProjectRules):
            let classifier = JavaInspectionFileClassifier(projectRoot: root, testRoots: javaTestSourceRoots)
            let inspector = javaSupport.makeBatchInspector()
            let options = JavaBatchInspector.Options(
                profile: profile, classifier: classifier, onlyRules: onlyRules, includeProjectRules: includeProjectRules
            )
            run.task = Task { [weak self, weak run] in
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
        case .swift(let scope, let inspection, let onlyRules, let resolver):
            let options = SwiftBatchInspector.Options(inspection: inspection, onlyRules: onlyRules, optionsForFile: resolver)
            run.task = Task { [weak self, weak run] in
                let files = await Task.detached(priority: .userInitiated) {
                    scope.resolve(projectRoots: root.map { [$0] } ?? [])
                }.value
                guard let self, let run else { return }
                let text = self.inspectionTextSource()
                for await event in SwiftBatchInspector().run(files: files, options: options, text: text) {
                    switch event {
                    case .started(let total): run.progress(done: 0, total: total)
                    case .file(let url, let findings): run.record(findings.map(IDEInspectionFinding.init), for: url)
                    case .progress(let done, let total): run.progress(done: done, total: total)
                    case .finished(let cancelled): run.finish(cancelled: cancelled)
                    }
                }
                if run.state == .running { run.finish(cancelled: Task.isCancelled) }
            }
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
        switch entry.inspection.origin {
        case .java(let inspection):
            let style: JavaSuppressionStyle = preferences.javaSuppressWithComment ? .comment : .annotation
            return JavaInspectionQuickFixes.actions(for: inspection, in: text, suppressionStyle: style)
        case .swift(let located):
            return SwiftInspectionQuickFixes.actions(for: located, in: text, options: swiftInspectionOptions(for: entry.url))
        }
    }

    /// The fixes and Suppress actions for a Problems row from an inspection.
    func quickFixes(for row: ProblemRow) async -> [CodeAction] {
        guard let text = await inspectionTextSource()(row.url) else { return [] }
        switch row.diagnostic.source {
        case "java-inspection":
            let style: JavaSuppressionStyle = preferences.javaSuppressWithComment ? .comment : .annotation
            return JavaInspectionQuickFixes.actions(for: row.diagnostic, in: text, suppressionStyle: style)
        case SwiftInspection.diagnosticSource:
            guard let code = row.diagnostic.code else { return [] }
            return SwiftInspectionQuickFixes.actions(
                ruleCode: code, range: row.diagnostic.range, message: row.diagnostic.message, in: text,
                options: swiftInspectionOptions(for: row.url)
            )
        default:
            return []
        }
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
        await applyInspectionFixAll(ruleCode: rule.code, in: run, urls: urls)
    }

    /// The same for either language's rule, by code.
    func applyInspectionFixAll(ruleCode: String, in run: IDEInspectionRun, urls: Set<URL>? = nil) async {
        let title = run.language.rule(code: ruleCode)?.title ?? ruleCode
        let entries = run.entries.filter {
            $0.inspection.id == ruleCode && !run.excludedKeys.contains($0.key) && (urls?.contains($0.url) ?? true)
        }
        guard !entries.isEmpty else { return }
        let touched = Array(Set(entries.map(\.url)))
        let outcome = await fixAll(ruleCodes: [ruleCode], language: run.language, in: touched)
        guard outcome.fixedCount > 0 else {
            notifications.post("Nothing to fix", detail: "'\(title)' has no automatic fix for these results.", category: .general)
            return
        }
        await reinspect(touched, in: run, handled: entries)
        notifications.post(
            "Fixed \(outcome.fixedCount) problem\(outcome.fixedCount == 1 ? "" : "s") in \(outcome.fileCount) file\(outcome.fileCount == 1 ? "" : "s")",
            detail: title, category: .general, action: .showProblems
        )
    }

    /// Fixes every finding of `rules` in `files` (Run Inspection by Name ▸ Fix All) as one action.
    func fixAll(rules: Set<JavaInspectionRule>, in files: [URL]) async -> (fixedCount: Int, fileCount: Int) {
        await fixAll(ruleCodes: Set(rules.map(\.code)), language: .java, in: files)
    }

    func fixAll(ruleCodes: Set<String>, language: IDEInspectionLanguage, in files: [URL]) async -> (fixedCount: Int, fileCount: Int) {
        let source = inspectionTextSource()
        var changes: [URL: [TextEdit]] = [:]
        var fixed = 0
        for url in files {
            if Task.isCancelled { break }
            guard let text = await source(url) else { continue }
            let found: (edits: [TextEdit], count: Int)
            switch language {
            case .java:
                let rules = Set(ruleCodes.compactMap(JavaInspectionRule.init(code:)))
                let result = await JavaBatchFixer.fixAll(
                    rules: rules, in: text, url: url, index: javaSupport.javaIndex, languageLevel: javaSupport.inspectionLanguageLevel(url)
                )
                found = (result.edits, result.fixedCount)
            case .swift:
                let rules = Set(ruleCodes.compactMap(SwiftInspectionRule.init(code:)))
                let result = SwiftBatchFixer.fixAll(rules: rules, in: text, options: swiftInspectionOptions(for: url))
                found = (result.edits, result.fixedCount)
            }
            guard !found.edits.isEmpty else { continue }
            changes[url] = found.edits
            fixed += found.count
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
        let text = inspectionTextSource()
        switch launch.backend {
        case .java(_, let profile, let onlyRules, let includeProjectRules):
            let inspector = javaSupport.makeBatchInspector()
            let options = JavaBatchInspector.Options(
                profile: profile,
                classifier: JavaInspectionFileClassifier(projectRoot: project.rootURL, testRoots: javaTestSourceRoots),
                onlyRules: onlyRules, includeProjectRules: includeProjectRules
            )
            for url in urls {
                let fresh = await inspector.inspect(url: url, options: options, text: text)
                run.markResolved(handled.filter { $0.url == url }, newFindings: fresh.map(IDEInspectionFinding.init), for: url)
            }
        case .swift(_, let inspection, let onlyRules, let resolver):
            let options = SwiftBatchInspector.Options(inspection: inspection, onlyRules: onlyRules, optionsForFile: resolver)
            for url in urls {
                let fresh = await SwiftBatchInspector().inspect(url: url, options: options, text: text)
                run.markResolved(handled.filter { $0.url == url }, newFindings: fresh.map(IDEInspectionFinding.init), for: url)
            }
        }
    }

    // MARK: - Result actions

    func openInspectionResult(_ entry: IDEInspectionRun.Entry) {
        openProblem(ProblemRow(url: entry.url, diagnostic: entry.inspection.asDiagnostic()))
    }

    /// Opens a result's file at its first line (a file row has no problem of its own to jump to).
    func openInspectionFile(_ url: URL) {
        let zero = TextPosition(line: 0, column: 0, utf16Offset: 0)
        openProblem(ProblemRow(url: url, diagnostic: Diagnostic(
            severity: .information, message: "", range: EditorIntelligence.TextRange(start: zero, end: zero),
            source: "inspect-code"
        )))
    }

    /// Disables the rule in the active profile (Java) or in Settings ▸ Swift, and drops its results from the run.
    func disableInspection(_ rule: JavaInspectionRule) {
        inspections.edit { $0.setEnabled(false, for: rule) }
    }

    func disableInspection(code: String, language: IDEInspectionLanguage) {
        switch language {
        case .java:
            if let rule = JavaInspectionRule(code: code) { disableInspection(rule) }
        case .swift:
            if let rule = SwiftInspectionRule(code: code) { inspections.edit { $0.swift.setEnabled(false, for: rule) } }
        }
    }

    func showInspectionSettings(code: String, language: IDEInspectionLanguage) {
        switch language {
        case .java:
            if let rule = JavaInspectionRule(code: code) { showInspectionSettings(for: rule) }
        case .swift:
            inspections.focusedRuleCode = code
            requestedSettingsDomain = .swift
            showSettings()
        }
    }

    // MARK: - Commit check

    /// Inspects staged files with the active profile (no project-wide rules) and counts what a
    /// reader would call a problem: errors and warnings. Java only: the commit check has no Swift profile.
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
        let report = Self.inspectionReport(for: run, root: project.rootURL)
        let data = format == .sarif ? report.sarif() : Data(report.html().utf8)
        do {
            try data.write(to: url, options: .atomic)
            notifications.post("Exported inspection results", detail: url.lastPathComponent, category: .general, action: .revealInFinder(url.path))
        } catch {
            notifications.post("Could not export results", detail: error.localizedDescription, category: .general, severity: .error)
        }
    }

    /// A run's findings in the report's own terms (paths relative to the project, 1-based positions).
    static func inspectionReport(for run: IDEInspectionRun, root: URL?) -> JavaInspectionReport {
        let prefix = root.map { $0.standardizedFileURL.path + "/" }
        var entries: [JavaInspectionReport.Entry] = []
        for (url, findings) in run.results {
            let path = url.standardizedFileURL.path
            let shown = prefix.flatMap { path.hasPrefix($0) ? String(path.dropFirst($0.count)) : nil } ?? path
            for finding in findings {
                entries.append(JavaInspectionReport.Entry(
                    path: shown, ruleCode: finding.id, message: finding.message, severity: finding.severity.java,
                    line: finding.range.start.line + 1, column: finding.range.start.column + 1
                ))
            }
        }
        entries.sort { ($0.path, $0.line, $0.column, $0.ruleCode) < ($1.path, $1.line, $1.column, $1.ruleCode) }
        var rules: [String: JavaInspectionReport.RuleInfo] = [:]
        for code in Set(entries.map(\.ruleCode)) {
            if let rule = run.language.rule(code: code) {
                rules[code] = JavaInspectionReport.RuleInfo(title: rule.title, summary: rule.summary, group: rule.groupTitle)
            }
        }
        return JavaInspectionReport(title: run.title, entries: entries, toolName: "Umbra \(run.language.title) Inspections", rules: rules)
    }
}

enum IDEInspectionExportFormat {
    case sarif
    case html

    var fileExtension: String { self == .sarif ? "sarif" : "html" }
}
