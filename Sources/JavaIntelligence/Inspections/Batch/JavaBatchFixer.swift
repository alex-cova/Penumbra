import EditorIntelligence
import Foundation

/// What "Fix all" did to one file.
public struct JavaFixAllResult: Sendable, Equatable {
    /// The file's text after the fixes.
    public let text: String
    /// The same change as minimal edits against the original text.
    public let edits: [TextEdit]
    public let fixedCount: Int

    public var isEmpty: Bool { fixedCount == 0 }
}

/// Applies the quick fix of every finding of some rules in one file. Fixes that touch the same
/// text as an earlier one are left for the next pass, which re-inspects the patched text (a fix
/// can uncover another finding), at most `maxPasses` times.
public enum JavaBatchFixer {
    public static let maxPasses = 3

    public static func fixAll(
        rules: Set<JavaInspectionRule>,
        in original: String,
        url: URL,
        index: JavaIndex,
        thresholds: JavaInspectionThresholds = .standard
    ) async -> JavaFixAllResult {
        let fixable = rules.filter(\.hasQuickFix)
        guard !fixable.isEmpty else { return JavaFixAllResult(text: original, edits: [], fixedCount: 0) }
        var text = original
        var fixed = 0
        for _ in 0..<maxPasses {
            guard let tree = JavaSyntaxParser().parse(text), !tree.rootNode.hasError else { break }
            let found = await JavaInspectionPipeline.inspect(
                text: text, url: url, tree: tree, index: index, enabled: fixable, thresholds: thresholds
            )
            let live = JavaInspectionPipeline.suppressionFiltered(found, text: text)
            let chosen = chooseEdits(for: live.map { $0.asDiagnostic() }, tree: tree, source: text)
            guard !chosen.edits.isEmpty else { break }
            let patched = apply(chosen.edits, to: text)
            guard patched != text else { break }
            text = patched
            fixed += chosen.count
        }
        guard fixed > 0 else { return JavaFixAllResult(text: original, edits: [], fixedCount: 0) }
        return JavaFixAllResult(text: text, edits: JavaFormatEdits.edits(from: original, to: text), fixedCount: fixed)
    }

    /// The edits that fix every one of `diagnostics` that has a fix and does not collide with an
    /// earlier one, against `source` (for ⌥↩ "Fix all in file", which has the findings already).
    static func allEdits(for diagnostics: [Diagnostic], tree: JavaSyntaxTree, source: String) -> [TextEdit] {
        chooseEdits(for: diagnostics, tree: tree, source: source).edits.map { edit in
            TextEdit(range: textRange(of: edit.range, in: source), replacement: edit.replacement)
        }
    }

    private static func textRange(of range: NSRange, in text: String) -> EditorIntelligence.TextRange {
        EditorIntelligence.TextRange(start: position(at: range.location, in: text), end: position(at: NSMaxRange(range), in: text))
    }

    private static func position(at offset: Int, in text: String) -> TextPosition {
        let ns = text as NSString
        let clamped = min(max(0, offset), ns.length)
        var line = 0
        var lineStart = 0
        var index = 0
        while index < clamped {
            let unit = ns.character(at: index)
            index += 1
            if unit == 0x0A || (unit == 0x0D && !(index < ns.length && ns.character(at: index) == 0x0A)) {
                line += 1
                lineStart = index
            }
        }
        return TextPosition(line: line, column: clamped - lineStart, utf16Offset: clamped)
    }

    private static func chooseEdits(
        for rawDiagnostics: [Diagnostic], tree: JavaSyntaxTree, source: String
    ) -> (edits: [(range: NSRange, replacement: String)], count: Int) {
        let diagnostics = rawDiagnostics.sorted { $0.range.start.utf16Offset < $1.range.start.utf16Offset }
        var taken: [NSRange] = []
        var edits: [(range: NSRange, replacement: String)] = []
        var count = 0
        for diagnostic in diagnostics {
            let actions = JavaInspectionFixes.fixes(for: diagnostic, tree: tree, source: source)
            guard let action = actions.first(where: \.isPreferred) ?? actions.first, !action.edits.isEmpty else { continue }
            let ranges = action.edits.map { ProblemLocator.nsRange(for: $0.range, in: source) }
            guard !ranges.contains(where: { range in taken.contains { overlap($0, range) } }) else { continue }
            taken.append(contentsOf: ranges)
            for (edit, range) in zip(action.edits, ranges) { edits.append((range, edit.replacement)) }
            count += 1
        }
        return (edits, count)
    }

    private static func overlap(_ a: NSRange, _ b: NSRange) -> Bool {
        if a.length == 0 && b.length == 0 { return a.location == b.location }
        if a.length == 0 { return a.location > b.location && a.location < NSMaxRange(b) }
        if b.length == 0 { return b.location > a.location && b.location < NSMaxRange(a) }
        return NSIntersectionRange(a, b).length > 0
    }

    private static func apply(_ edits: [(range: NSRange, replacement: String)], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }
}
