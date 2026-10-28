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

    /// The largest text analysed. A file this size is almost always generated, and the parse is not incremental.
    public static let maximumUTF8Length = 1_500_000

    private struct Key: Hashable {
        let length: Int
        let hash: Int
        let options: SwiftInspectionOptions
    }

    private let options: OptionsSource
    private let cache: SwiftSyntaxParseCache
    private let lock = NSLock()
    private var recent: [(key: Key, analysis: SwiftInspectionPipeline.Analysis)] = []

    public init(options: @escaping OptionsSource = { .standard }, cache: SwiftSyntaxParseCache = .shared) {
        self.options = options
        self.cache = cache
    }

    public var currentOptions: SwiftInspectionOptions { options() }

    /// The analysis of `text` under the current options; the two most recent are kept.
    public func analysis(of text: String) -> SwiftInspectionPipeline.Analysis {
        guard text.utf8.count <= Self.maximumUTF8Length else { return .empty(for: "") }
        let options = options()
        let key = Key(length: text.utf8.count, hash: text.hashValue, options: options)
        if let hit = lock.withLock({ recent.first { $0.key == key }?.analysis }) { return hit }
        let analysis = SwiftInspectionPipeline.analyze(text: text, options: options, cache: cache)
        lock.withLock {
            recent.removeAll { $0.key == key }
            recent.append((key, analysis))
            if recent.count > 2 { recent.removeFirst() }
        }
        return analysis
    }

    /// Findings for a document, or none for one the inspections do not apply to.
    func analysis(for document: Document) -> SwiftInspectionPipeline.Analysis? {
        guard document.languageIdentifier == SwiftAnalysis.languageIdentifier,
              !document.contentSnapshot.isElided else { return nil }
        if let url = document.url, DependencySourceLocation.isGeneratedInterface(url) { return nil }
        return analysis(of: document.text)
    }
}

/// The commands the ⌥↩ menu hands the host for a Swift inspection; the argument is the rule's code.
public enum SwiftInspectionCommand {
    /// Switch the rule off.
    public static let disable = "swift.inspection.disable"
    /// Open the inspection settings on the rule.
    public static let configure = "swift.inspection.configure"
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
        return analysis.findings.map { $0.asDiagnostic(map: analysis.map) }
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
                let all = SwiftBatchFixer.fixAll(rules: [rule], in: document.text, options: currentOptions)
                if all.edits.count > 1 {
                    actions.append(CodeAction(title: "Fix all '\(rule.title)' problems in file", kind: "quickfix.fixAll", edits: all.edits))
                }
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
