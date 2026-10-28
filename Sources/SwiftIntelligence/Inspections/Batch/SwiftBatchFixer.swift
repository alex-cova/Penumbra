import EditorIntelligence
import Foundation

/// What "Fix all" did to one file.
public struct SwiftFixAllResult: Sendable, Equatable {
    /// The fixes as edits against the original text, none overlapping.
    public let edits: [TextEdit]
    public let fixedCount: Int

    public var isEmpty: Bool { fixedCount == 0 }
}

/// Applies the preferred fix of every finding of some rules in one file, in one pass over one analysis.
/// A fix that touches the same text as an earlier one is left for the next run, so every edit is exact
/// against the text that was analysed. A file that parses cleanly but would not after the edits gets none:
/// a fix never leaves a syntax error behind.
public enum SwiftBatchFixer {
    public static func fixAll(
        rules: Set<SwiftInspectionRule>, in original: String, options: SwiftInspectionOptions = .standard
    ) -> SwiftFixAllResult {
        let fixable = rules.filter(\.hasFixes)
        guard !fixable.isEmpty, original.utf8.count <= SwiftInspectionService.maximumUTF8Length else {
            return SwiftFixAllResult(edits: [], fixedCount: 0)
        }
        let analysis = SwiftInspectionPipeline.analyze(
            text: original, options: options.only(fixable), cache: SwiftSyntaxParseCache(capacity: 1)
        )
        return pick(from: analysis, original: original)
    }

    /// The same, plus the index-backed fixes (`unused-import`): the analysis also asks `lookup`
    /// about the rest of the project. For Inspect Code's Fix all, which runs after the index is ready.
    public static func fixAll(
        rules: Set<SwiftInspectionRule>, in original: String, options: SwiftInspectionOptions = .standard,
        url: URL, lookup: (any SwiftModuleSurfaceLookup)
    ) async -> SwiftFixAllResult {
        let fixable = rules.filter(\.hasFixes)
        guard !fixable.isEmpty, original.utf8.count <= SwiftInspectionService.maximumUTF8Length else {
            return SwiftFixAllResult(edits: [], fixedCount: 0)
        }
        let analysis = await SwiftInspectionPipeline.analyze(
            text: original, options: options.only(fixable), url: url, isTest: SwiftInspectionScope.isTest(url),
            lookup: lookup, cache: SwiftSyntaxParseCache(capacity: 1)
        )
        return pick(from: analysis, original: original)
    }

    private static func pick(
        from analysis: SwiftInspectionPipeline.Analysis, original: String
    ) -> SwiftFixAllResult {
        var taken: [Range<Int>] = []
        var chosen: [SwiftInspectionFix.Edit] = []
        var count = 0
        for finding in analysis.findings {
            guard let fix = finding.fixes.first, !fix.edits.isEmpty else { continue }
            let spans = fix.edits.map(\.bytes)
            guard !spans.contains(where: { span in taken.contains { touches($0, span) } }) else { continue }
            taken.append(contentsOf: spans)
            chosen.append(contentsOf: fix.edits)
            count += 1
        }
        guard count > 0, leavesParseable(original, applying: chosen) else { return SwiftFixAllResult(edits: [], fixedCount: 0) }
        let edits = chosen.sorted { $0.bytes.lowerBound < $1.bytes.lowerBound }
            .map { TextEdit(range: analysis.map.range(bytes: $0.bytes), replacement: $0.replacement) }
        return SwiftFixAllResult(edits: edits, fixedCount: count)
    }

    private static func touches(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        a.lowerBound <= b.upperBound && b.lowerBound <= a.upperBound
    }

    private static func leavesParseable(_ original: String, applying edits: [SwiftInspectionFix.Edit]) -> Bool {
        if SwiftSyntaxDocument.parse(original).hasSyntaxErrors { return true }
        var bytes = Array(original.utf8)
        for edit in edits.sorted(by: { $0.bytes.lowerBound > $1.bytes.lowerBound }) {
            bytes.replaceSubrange(edit.bytes, with: Array(edit.replacement.utf8))
        }
        return !SwiftSyntaxDocument.parse(String(decoding: bytes, as: UTF8.self)).hasSyntaxErrors
    }
}

/// The fixes of one Inspect Code result and the suppression comment for it, from its file's current text
/// (the list holds only positions, and the file may have changed since).
public enum SwiftInspectionQuickFixes {
    public static func actions(
        for finding: SwiftLocatedInspection, in text: String, options: SwiftInspectionOptions = .standard
    ) -> [CodeAction] {
        actions(ruleCode: finding.inspection.id, range: finding.range, message: finding.inspection.message, in: text, options: options)
    }

    /// The same for a finding known only by its rule, place and message (a Problems row).
    public static func actions(
        ruleCode: String, range: EditorIntelligence.TextRange, message: String, in text: String,
        options: SwiftInspectionOptions = .standard
    ) -> [CodeAction] {
        guard let rule = SwiftInspectionRule(code: ruleCode),
              text.utf8.count <= SwiftInspectionService.maximumUTF8Length else { return [] }
        let analysis = SwiftInspectionPipeline.analyze(
            text: text, options: options.only([rule]), cache: SwiftSyntaxParseCache(capacity: 1)
        )
        let candidates = analysis.findings.filter { $0.id == rule.code }
        let current = candidates.first { analysis.map.range(bytes: $0.bytes) == range && $0.message == message }
            ?? candidates.first { analysis.map.range(bytes: $0.bytes) == range }
        guard let current else { return [] }
        var actions = current.fixes.enumerated().map { $1.codeAction(map: analysis.map, isPreferred: $0 == 0) }
        if let suppression = SwiftInspectionPipeline.suppressionFix(for: current, in: analysis) {
            actions.append(suppression.codeAction(map: analysis.map))
        }
        return actions
    }
}
