import XCTest
@testable import Penumbra
@testable import JavaIntelligence
import EditorIntelligence

/// The Phase 3 command-completion corpus (`Fixtures/JavaCommandCorpus/cases`). Unlike the
/// main Java corpus it composes providers the way the editor does: the Java provider for
/// `..` targets, and the generic command provider for read-only files. Directives:
///
/// - `mode: dotDot|readOnly` — how the case was triggered.
/// - `contains`, `excludes`, `top1`, `top5` — labels (`CompletionCorpusRunner.checkLabels`).
/// - `filter: def` — the read-only virtual filter to rank by.
/// - `command:` / `action:` / `selects:` — an item whose editor action has this id and
///   whose `selecting:` range covers exactly this text.
/// - `accepts:` / `acceptAction:` / `acceptSelects:` / `yields:` — simulate the
///   controller's acceptance (dots and filter deleted, selection set to `selects`),
///   then the edited text must contain `yields`.
/// - `reference:` — Copy Reference at the caret produces this string.
final class JavaCommandCorpusTests: XCTestCase {
    func testCommandCorpus() async throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/JavaCommandCorpus/cases")
        let cases = try CompletionCorpusRunner.Case.load(from: directory, extension: "java")
        XCTAssertEqual(cases.map(\.name), [
            "CommandDotDotAccept", "CommandDotDotBlock", "CommandDotDotExpression",
            "CommandDotDotFilter", "ReadOnlyCommandCopyReference", "ReadOnlyCommandFilter"
        ])
        for corpusCase in cases {
            let result = await run(corpusCase)
            for failure in result.hardFailures + result.scoredFailures {
                XCTFail("\(corpusCase.name): \(failure)")
            }
        }
    }

    private func run(_ corpusCase: CompletionCorpusRunner.Case) async -> CompletionCorpusRunner.Result {
        var result = CompletionCorpusRunner.Result(name: corpusCase.name)
        let document = corpusCase.document(language: "java")
        let caret = document.cursor.position
        let isReadOnly = corpusCase.directives["mode"] == "readOnly"
        let items: [CompletionItem]
        let context: CompletionContext
        if isReadOnly {
            context = CompletionContext(
                document: document, cursor: document.cursor, trigger: .manual, prefix: "",
                range: TextRange(start: caret, end: caret), commandMode: .readOnly
            )
            let provider = EditorCommandCompletionProvider(
                settingsBox: CommandCompletionSettingsBox(CommandCompletionSettings(readOnlyEnabled: true))
            )
            items = await provider.commandItems(context: context)
        } else {
            context = makeCompletionContext(document: document, trigger: .manual, commandMode: .dotDot)
            items = await JavaCompletionProvider(index: JavaIndex()).provide(context: context)
        }
        let prefix = isReadOnly ? (corpusCase.directives["filter"] ?? "") : corpusCase.prefix
        let ranked = CompletionCorpusRunner.rank(items, prefix: prefix)
        CompletionCorpusRunner.checkLabels(corpusCase, ranked: ranked, into: &result)

        let directives = corpusCase.directives
        let ns = corpusCase.text as NSString
        func selectedText(_ item: CompletionItem) -> String? {
            guard case .editorAction(_, let selecting) = item.command, let selecting else { return nil }
            return ns.substring(with: NSRange(
                location: selecting.start.utf16Offset,
                length: selecting.end.utf16Offset - selecting.start.utf16Offset
            ))
        }
        if let label = directives["command"] {
            guard let item = ranked.first(where: { $0.label == label && $0.command != nil }) else {
                result.hardFailures.append("no command item \(label); got \(ranked.map(\.label))")
                return result
            }
            if let wanted = directives["action"], case .editorAction(let id, _) = item.command, id != wanted {
                result.hardFailures.append("\(label) runs \(id), expected \(wanted)")
            }
            if let wanted = directives["selects"], selectedText(item) != wanted {
                result.hardFailures.append("\(label) selects \(selectedText(item) ?? "nil"), expected \(wanted)")
            }
        }
        if let label = directives["accepts"] {
            guard let item = ranked.first(where: { $0.label == label && selectedText($0) != nil }) else {
                result.hardFailures.append("no selectable command item \(label); got \(ranked.map(\.label))")
                return result
            }
            if let wanted = directives["acceptAction"], case .editorAction(let id, _) = item.command, id != wanted {
                result.hardFailures.append("accepting \(label) runs \(id), expected \(wanted)")
            }
            if let wanted = directives["acceptSelects"], selectedText(item) != wanted {
                result.hardFailures.append("accepting \(label) selects \(selectedText(item) ?? "nil"), expected \(wanted)")
            }
            // The controller deletes the trigger dots and typed filter, then selects.
            var start = corpusCase.caretUTF16Offset - corpusCase.prefix.utf16.count
            while start > 0, ns.character(at: start - 1) == 0x2E { start -= 1 } // '.'
            let edited = ns.replacingCharacters(
                in: NSRange(location: start, length: corpusCase.caretUTF16Offset - start), with: ""
            )
            if let wanted = directives["yields"], !edited.contains(wanted) {
                result.hardFailures.append("accepting \(label) yields \(edited.debugDescription), expected it to contain \(wanted)")
            }
        }
        if let wanted = directives["reference"] {
            let provider = JavaSymbolReferenceProvider(index: JavaIndex())
            let reference = await provider.symbolReference(for: document, at: caret)
            if reference != wanted {
                result.hardFailures.append("reference \(reference ?? "nil"), expected \(wanted)")
            }
        }
        return result
    }
}
