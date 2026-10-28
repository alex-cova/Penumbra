import EditorIntelligence
import Foundation

/// Runs the native Swift inspections for the editor and remembers the last answers, so the squiggles
/// (``SwiftInspectionDiagnosticProvider``) and the ⌥↩ fixes (``SwiftCodeActionProvider``) of one text share
/// one analysis.
///
/// The options come from the host through ``init(options:)`` and are read for every analysis, so a rule
/// switched off in Settings takes effect on the next pass without restarting anything.
public final class SwiftInspectionService: @unchecked Sendable {
    public typealias OptionsSource = @Sendable () -> SwiftInspectionOptions
    /// The options for one file (nil for text without a file): a profile's scopes can differ per file.
    public typealias FileOptionsSource = @Sendable (URL?) -> SwiftInspectionOptions

    /// The largest text analysed. A file this size is almost always generated, and the parse is not incremental.
    public static let maximumUTF8Length = 1_500_000

    private struct Key: Hashable {
        let length: Int
        let hash: Int
        let options: SwiftInspectionOptions
    }

    private let options: FileOptionsSource
    private let cache: SwiftSyntaxParseCache
    private let lock = NSLock()
    private var recent: [(key: Key, analysis: SwiftInspectionPipeline.Analysis)] = []
    /// Project-wide findings per file, valid for the text they were computed from (a save, an open
    /// or a profile change; never a keystroke). The synchronous pass merges them when the hash
    /// matches, so the next edit drops them.
    private var indexFindings: [URL: (textHash: Int, findings: [SwiftInspection])] = [:]
    private var indexLookup: (any SwiftModuleSurfaceLookup)?
    private var indexResultHandler: (@Sendable (URL, [Diagnostic]) -> Void)?

    public init(options: @escaping OptionsSource = { .standard }, cache: SwiftSyntaxParseCache = .shared) {
        self.options = { _ in options() }
        self.cache = cache
    }

    public init(optionsForFile: @escaping FileOptionsSource, cache: SwiftSyntaxParseCache = .shared) {
        self.options = optionsForFile
        self.cache = cache
    }

    public var currentOptions: SwiftInspectionOptions { options(nil) }

    /// What the index-backed rules ask the rest of the project. `nil` until the host sets it.
    public func setIndexLookup(_ lookup: (any SwiftModuleSurfaceLookup)?) {
        lock.withLock { indexLookup = lookup }
    }

    /// Called with the merged diagnostics of each finished index pass. The host refreshes the
    /// file's editors (a save changes no text, so no refresh would otherwise happen).
    public func setIndexResultHandler(_ handler: (@Sendable (URL, [Diagnostic]) -> Void)?) {
        lock.withLock { indexResultHandler = handler }
    }

    /// Drops every stored index finding (the options changed, so they were computed stale).
    public func clearIndexFindings() {
        lock.withLock {
            indexFindings.removeAll()
            recent.removeAll()
        }
    }

    /// The analysis of `text` (the file `url`, when it is one) under the current options; the two most recent are kept.
    /// Index findings merge in when they belong to exactly this text.
    public func analysis(of text: String, url: URL? = nil) -> SwiftInspectionPipeline.Analysis {
        guard text.utf8.count <= Self.maximumUTF8Length else { return .empty(for: "") }
        let options = options(url)
        let key = Key(length: text.utf8.count, hash: text.hashValue, options: options)
        if let hit = lock.withLock({ recent.first { $0.key == key }?.analysis }) { return hit }
        var analysis = SwiftInspectionPipeline.analyze(text: text, options: options, cache: cache)
        let (stored, stale) = storedFindings(for: url, textHash: text.hashValue, options: options)
        if !stale, !stored.isEmpty {
            analysis.findings.append(contentsOf: stored)
            analysis.findings.sort { $0.bytes.lowerBound < $1.bytes.lowerBound }
        }
        lock.withLock {
            recent.removeAll { $0.key == key }
            recent.append((key, analysis))
            if recent.count > 2 { recent.removeFirst() }
        }
        return analysis
    }

    /// The analysis for display plus whether its index findings belong to older text. A stale entry
    /// still merges (its byte ranges clamp onto the new text), so the markers stay shifted instead
    /// of flickering until the next save.
    func analysisAllowingStale(of text: String, url: URL?) -> (analysis: SwiftInspectionPipeline.Analysis, indexStale: Bool) {
        guard text.utf8.count <= Self.maximumUTF8Length else { return (.empty(for: ""), false) }
        let options = options(url)
        let (_, stale) = storedFindings(for: url, textHash: text.hashValue, options: options)
        // Fresh or absent findings go through the cached pass; only a stale entry recomputes.
        guard stale else { return (analysis(of: text, url: url), false) }
        var analysis = SwiftInspectionPipeline.analyze(text: text, options: options, cache: cache)
        let (stored, _) = storedFindings(for: url, textHash: text.hashValue, options: options)
        if !stored.isEmpty {
            analysis.findings.append(contentsOf: stored)
            analysis.findings.sort { $0.bytes.lowerBound < $1.bytes.lowerBound }
        }
        return (analysis, true)
    }

    /// The stored index findings for `url` that the current options still enable, and whether they
    /// belong to older text.
    private func storedFindings(
        for url: URL?, textHash: Int, options: SwiftInspectionOptions
    ) -> (findings: [SwiftInspection], stale: Bool) {
        guard let url else { return ([], false) }
        let key = url.standardizedFileURL
        guard let stored = lock.withLock({ indexFindings[key] }) else { return ([], false) }
        let enabled = stored.findings.filter { finding in
            guard let rule = SwiftInspectionRule(code: finding.id) else { return false }
            return rule.needsIndex && options.isEnabled(rule)
        }
        if enabled.isEmpty { return ([], false) }
        return (enabled, stored.textHash != textHash)
    }

    /// Runs the index-backed rules for one file (a save, an open or a profile change — never a
    /// keystroke) and stores the findings under the analyzed text's hash. A cancelled pass stores
    /// and pushes nothing; the caller keeps one pass per document in flight, so a newer save
    /// cancels the older one before it lands.
    public func runIndexInspections(for url: URL, text: String) async {
        let key = url.standardizedFileURL
        let options = options(url)
        let lookup = lock.withLock({ indexLookup })
        guard options.enabledRules.contains(where: { $0.needsIndex }) else {
            lock.withLock {
                indexFindings.removeValue(forKey: key)
                recent.removeAll()
            }
            return
        }
        // No up-to-date shortcut: another file's save can change what is unused here, so every
        // trigger re-asks the index (never on a keystroke, and one pass per document in flight).
        let analysis = await SwiftInspectionPipeline.analyze(
            text: text, options: options, url: url, isTest: SwiftInspectionScope.isTest(url), lookup: lookup
        )
        guard !Task.isCancelled else { return }
        let extra = analysis.findings.filter { SwiftInspectionRule(code: $0.id)?.needsIndex == true }
        let diagnostics = extra.filter { $0.severity != .noHighlighting }.map { $0.asDiagnostic(map: analysis.map) }
        let handler = lock.withLock { () -> (@Sendable (URL, [Diagnostic]) -> Void)? in
            indexFindings[key] = (text.hashValue, extra)
            // The cached synchronous analyses predate these findings; drop them so the next
            // editor refresh merges.
            recent.removeAll()
            return indexResultHandler
        }
        handler?(url, diagnostics)
    }

    /// Findings for a document, or none for one the inspections do not apply to.
    func analysis(for document: Document) -> SwiftInspectionPipeline.Analysis? {
        guard document.languageIdentifier == SwiftAnalysis.languageIdentifier,
              !document.contentSnapshot.isElided else { return nil }
        if let url = document.url, DependencySourceLocation.isGeneratedInterface(url) { return nil }
        return analysis(of: document.text, url: document.url)
    }
}

/// The commands the ⌥↩ menu hands the host for a Swift inspection; the argument is the rule's code.
public enum SwiftInspectionCommand {
    /// Switch the rule off.
    public static let disable = "swift.inspection.disable"
    /// Open the inspection settings on the rule.
    public static let configure = "swift.inspection.configure"
    /// Set the rule to "No highlighting (fix available)".
    public static let quiet = "swift.inspection.quiet"
}

/// The inspections' squiggles. Findings are `Diagnostic`s with the source `swift-inspection` and the rule id
/// as their code.
public struct SwiftInspectionDiagnosticProvider: DiagnosticProvider {
    public let name = SwiftInspection.diagnosticSource
    private let service: SwiftInspectionService

    public init(service: SwiftInspectionService) {
        self.service = service
    }

    public func diagnostics(for document: Document) async -> [Diagnostic] {
        guard let analysis = service.analysis(for: document), !Task.isCancelled else { return [] }
        // "No highlighting" findings are not drawn or listed; their fixes stay on ⌥↩.
        return analysis.findings.filter { $0.severity != .noHighlighting }.map { $0.asDiagnostic(map: analysis.map) }
    }

    /// The diagnostics plus `swift-inspection` when the merged index findings belong to older text:
    /// the previous save's markers stay (shifted onto the new text) instead of flickering.
    public func diagnosticsWithFreshness(for document: Document) async -> (diagnostics: [Diagnostic], staleSources: Set<String>) {
        guard document.languageIdentifier == SwiftAnalysis.languageIdentifier,
              !document.contentSnapshot.isElided,
              let url = document.url, !DependencySourceLocation.isGeneratedInterface(url),
              !Task.isCancelled
        else { return ([], []) }
        let (analysis, indexStale) = service.analysisAllowingStale(of: document.text, url: url)
        guard !Task.isCancelled else { return ([], []) }
        let diagnostics = analysis.findings.filter { $0.severity != .noHighlighting }.map { $0.asDiagnostic(map: analysis.map) }
        return (diagnostics, indexStale ? [SwiftInspection.diagnosticSource] : [])
    }
}

extension SwiftInspectionService {
    /// The quick fixes for the findings at `position`: each finding's own fixes, then a suppression comment.
    func codeActions(for document: Document, at position: TextPosition) -> [CodeAction] {
        guard let analysis = analysis(for: document) else { return [] }
        var actions: [CodeAction] = []
        var seenRules = Set<String>()
        for finding in analysis.findings {
            let range = analysis.map.range(bytes: finding.bytes)
            guard Self.contains(range, position) else { continue }
            for (index, fix) in finding.fixes.enumerated() {
                actions.append(fix.codeAction(map: analysis.map, isPreferred: index == 0))
            }
            if let suppression = SwiftInspectionPipeline.suppressionFix(for: finding, in: analysis) {
                actions.append(suppression.codeAction(map: analysis.map))
            }
            // Once per rule: every fix of it in the file, and the commands to switch it off or open its settings.
            guard let rule = SwiftInspectionRule(code: finding.id), seenRules.insert(finding.id).inserted else { continue }
            if rule.hasFixes, analysis.findings.filter({ $0.id == finding.id }).count > 1 {
                let all = SwiftBatchFixer.fixAll(rules: [rule], in: document.text, options: options(document.url))
                if all.edits.count > 1 {
                    actions.append(CodeAction(title: "Fix all '\(rule.title)' problems in file", kind: "quickfix.fixAll", edits: all.edits))
                }
            }
            if finding.severity != .noHighlighting {
                actions.append(CodeAction(
                    title: "Turn off highlighting for '\(rule.title)' (keep fix)", kind: "inspection",
                    edits: [], command: CodeActionCommand(id: SwiftInspectionCommand.quiet, arguments: [rule.code])
                ))
            }
            actions.append(CodeAction(
                title: "Disable inspection '\(rule.title)'", kind: "inspection",
                edits: [], command: CodeActionCommand(id: SwiftInspectionCommand.disable, arguments: [rule.code])
            ))
            actions.append(CodeAction(
                title: "Edit inspection settings…", kind: "inspection",
                edits: [], command: CodeActionCommand(id: SwiftInspectionCommand.configure, arguments: [rule.code])
            ))
        }
        return actions
    }

    /// Whether `position` is in `range`, both ends included (a caret at the end of a word is on it).
    private static func contains(_ range: EditorIntelligence.TextRange, _ position: TextPosition) -> Bool {
        let point = (position.line, position.column)
        return (range.start.line, range.start.column) <= point && point <= (range.end.line, range.end.column)
    }
}
