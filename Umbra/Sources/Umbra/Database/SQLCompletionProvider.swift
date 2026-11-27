import DatabaseKit
import EditorIntelligence
import Foundation

/// What one console knows about its database: the dialect and a catalog snapshot, both in memory,
/// so a keystroke reads this and never the database.
public struct SQLCompletionSnapshot: Sendable, Equatable {
    public var engine: DatabaseEngine
    public var catalog: SQLCatalog

    public init(engine: DatabaseEngine, catalog: SQLCatalog) {
        self.engine = engine
        self.catalog = catalog
    }

    var dialect: SQLDialect? { SQLDialect(engine: engine) }
}

/// The snapshots of every console, by document. One store serves completion, diagnostics and
/// hover, so they always agree about the schema.
final class SQLSnapshotStore: @unchecked Sendable {
    // Justification: one lock guards the one dictionary; every method takes it for a dictionary
    // read or write and nothing else, so there is no state to race on.
    private let lock = NSLock()
    private var snapshots: [UUID: SQLCompletionSnapshot] = [:]

    func set(_ snapshot: SQLCompletionSnapshot?, for documentID: DocumentID) {
        lock.withLock {
            if let snapshot { snapshots[documentID.uuid] = snapshot } else { snapshots.removeValue(forKey: documentID.uuid) }
        }
    }

    func snapshot(for documentID: DocumentID) -> SQLCompletionSnapshot? {
        lock.withLock { snapshots[documentID.uuid] }
    }
}

/// How much text around the caret the engine reads: enough for any realistic statement, bounded so
/// a very large script cannot make a keystroke slow. The window is cut at line boundaries.
enum SQLWindow {
    static let radius = 24_000

    static func around(_ offset: Int, in document: Document) -> (text: String, start: Int) {
        let total = document.contentSnapshot.utf16Length
        var start = max(0, offset - radius)
        var end = min(total, offset + radius)
        if start > 0 {
            // Begin at the next line, so the window never starts inside a string or a comment.
            let probe = document.substring(utf16Offset: start, length: min(512, total - start))
            if let newline = probe.utf16.firstIndex(of: 10) {
                start += probe.utf16.distance(from: probe.utf16.startIndex, to: newline) + 1
            }
        }
        if end < total {
            let probe = document.substring(utf16Offset: max(start, end - 512), length: min(512, total - max(start, end - 512)))
            if let newline = probe.utf16.lastIndex(of: 10) {
                end = max(start, end - 512) + probe.utf16.distance(from: probe.utf16.startIndex, to: newline)
            }
        }
        let text = document.substring(utf16Offset: start, length: max(0, end - start))
        return (text, start)
    }
}

/// Semantic completion for SQL consoles: aliases, CTEs, derived tables, subqueries, INSERT targets,
/// join conditions from declared foreign keys, dialect-specific functions and types.
///
/// Primary only for `sql` documents that are consoles (which is what having a snapshot means), so
/// plain `.sql` files and MongoDB consoles keep ordinary completion.
final class SQLCompletionProvider: CompletionProvider, @unchecked Sendable {
    let name = "SQL"
    let store = SQLSnapshotStore()

    func setSnapshot(_ snapshot: SQLCompletionSnapshot?, for documentID: DocumentID) {
        store.set(snapshot, for: documentID)
    }

    func removeSnapshot(for documentID: DocumentID) {
        store.set(nil, for: documentID)
    }

    func isPrimary(for context: CompletionContext) -> Bool {
        guard context.document.languageIdentifier == "sql",
              let snapshot = store.snapshot(for: context.document.id), snapshot.dialect != nil else { return false }
        return true
    }

    func provide(context: CompletionContext) async -> [CompletionItem] {
        guard context.document.languageIdentifier == "sql",
              let snapshot = store.snapshot(for: context.document.id) else { return [] }
        let result = complete(context, snapshot: snapshot)
        guard !result.items.isEmpty else { return [] }
        let caret = context.cursor.position
        let caretOffset = caret.utf16Offset
        let replaceStart = result.replacement.location
        // The replaced word is on the caret's line, so its column is the caret's minus its length.
        let startColumn = max(0, caret.column - (caretOffset - replaceStart))
        let range = TextRange(
            start: TextPosition(line: caret.line, column: startColumn, utf16Offset: replaceStart),
            end: caret
        )
        let needsSpace = nextCharacterIsNotWhitespace(context)
        let count = Double(result.items.count)
        return result.items.enumerated().map { index, item in
            let isKeyword = item.kind == .keyword && item.label != "*"
            let insert = isKeyword && needsSpace ? item.insertText + " " : item.insertText
            return CompletionItem(
                label: item.label,
                insertText: insert,
                kind: Self.kind(item.kind),
                range: range,
                source: name,
                sortText: String(format: "%05d", index),
                filterText: item.label,
                detail: item.detail,
                priority: count - Double(index),
                caretOffset: item.caretOffsetFromEnd.map { (insert as NSString).length - $0 }
            )
        }
    }

    private func complete(_ context: CompletionContext, snapshot: SQLCompletionSnapshot) -> SQLCompletionResult {
        guard let dialect = snapshot.dialect else {
            return SQLCompletionResult(replacement: NSRange(location: 0, length: 0), items: [], context: "no-dialect")
        }
        let caret = context.cursor.position.utf16Offset
        let (text, start) = SQLWindow.around(caret, in: context.document)
        var result = SQLCompletionEngine.complete(text: text, caret: caret - start, dialect: dialect, catalog: snapshot.catalog)
        result.replacement.location += start
        return result
    }

    private func nextCharacterIsNotWhitespace(_ context: CompletionContext) -> Bool {
        let next = context.document.substring(utf16Offset: context.cursor.position.utf16Offset, length: 1)
        guard let scalar = next.unicodeScalars.first else { return true }
        return !CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func kind(_ kind: SQLCompletionItem.Kind) -> CompletionItemKind {
        switch kind {
        case .keyword: .keyword
        case .table, .view, .cte: .class
        case .column: .field
        case .function: .function
        case .alias: .variable
        case .schema: .module
        case .type: .type
        case .joinCondition: .text
        }
    }
}

/// Problems in a console, read from the same snapshot as completion. Silent while the schema is
/// still loading (an unloaded object is not an unknown one), and for documents with no console.
final class SQLDiagnosticProvider: DiagnosticProvider, @unchecked Sendable {
    let name = "SQL"
    private let store: SQLSnapshotStore

    init(store: SQLSnapshotStore) { self.store = store }

    /// Past this size the whole-document check is skipped rather than made slow.
    static let maximumLength = 400_000

    func diagnostics(for document: Document) async -> [Diagnostic] {
        guard document.languageIdentifier == "sql", let snapshot = store.snapshot(for: document.id),
              let dialect = snapshot.dialect, document.contentSnapshot.utf16Length <= Self.maximumLength else { return [] }
        let text = document.text
        let lineStarts = Self.lineStarts(text)
        return SQLDiagnosticsEngine.diagnose(text: text, dialect: dialect, catalog: snapshot.catalog).map { finding in
            let end = finding.range.location + finding.range.length
            return Diagnostic(
                severity: finding.severity == .error ? .error : (finding.severity == .warning ? .warning : .information),
                message: finding.message,
                range: TextRange(start: Self.position(finding.range.location, lineStarts), end: Self.position(end, lineStarts)),
                source: name,
                code: finding.code
            )
        }
    }

    static func lineStarts(_ text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        return starts
    }

    static func position(_ offset: Int, _ starts: [Int]) -> TextPosition {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        let line = max(0, low - 1)
        return TextPosition(line: line, column: offset - starts[line], utf16Offset: offset)
    }
}

/// Quick documentation: a column's type and keys, a table's columns, a function's signature.
final class SQLHoverProvider: HoverProvider, @unchecked Sendable {
    let name = "SQL"
    private let store: SQLSnapshotStore

    init(store: SQLSnapshotStore) { self.store = store }

    func provide(context: HoverContext) async -> HoverResult? {
        guard context.document.languageIdentifier == "sql", let snapshot = store.snapshot(for: context.document.id),
              let dialect = snapshot.dialect else { return nil }
        let caret = context.cursor.position.utf16Offset
        let (text, start) = SQLWindow.around(caret, in: context.document)
        guard let hover = SQLAssist.hover(text: text, caret: caret - start, dialect: dialect, catalog: snapshot.catalog) else { return nil }
        let startOffset = hover.range.location + start
        let endOffset = startOffset + hover.range.length
        let position = context.cursor.position
        return HoverResult(
            contents: hover.markdown,
            range: TextRange(
                start: TextPosition(line: position.line, column: max(0, position.column - (caret - startOffset)), utf16Offset: startOffset),
                end: TextPosition(line: position.line, column: position.column + (endOffset - caret), utf16Offset: endOffset)
            ),
            source: name
        )
    }
}

struct SQLSignatureHelpProvider: SignatureHelpProviding {
    let store: SQLSnapshotStore

    func signatureHelp(for document: Document, at position: TextPosition) async -> ParameterHintsModel? {
        guard document.languageIdentifier == "sql", let dialect = store.snapshot(for: document.id)?.dialect else { return nil }
        let caret = position.utf16Offset
        let (text, start) = SQLWindow.around(caret, in: document)
        guard let hint = SQLAssist.signatureHelp(text: text, caret: caret - start, dialect: dialect) else { return nil }
        return ParameterHintsModel(signatures: [hint.signature], activeParameter: hint.activeParameter)
    }
}

struct SQLCodeActionProvider: CodeActionProviding {
    let store: SQLSnapshotStore

    func codeActions(for document: Document, at position: TextPosition, diagnostics: [Diagnostic]) async -> [CodeAction] {
        guard document.languageIdentifier == "sql", let snapshot = store.snapshot(for: document.id),
              let dialect = snapshot.dialect else { return [] }
        let caret = position.utf16Offset
        let (text, start) = SQLWindow.around(caret, in: document)
        let localCaret = caret - start
        let lineStarts = SQLDiagnosticProvider.lineStarts(text)
        let localPosition = SQLDiagnosticProvider.position(localCaret, lineStarts)
        func edit(_ range: NSRange, replacement: String) -> TextEdit {
            func at(_ offset: Int) -> TextPosition {
                let local = SQLDiagnosticProvider.position(offset, lineStarts)
                return TextPosition(line: position.line + local.line - localPosition.line,
                                    column: local.column, utf16Offset: start + offset)
            }
            return TextEdit(range: TextRange(start: at(range.location), end: at(NSMaxRange(range))), replacement: replacement)
        }
        var actions: [CodeAction] = []
        if let expansion = SQLAssist.expandStar(text: text, caret: localCaret, dialect: dialect, catalog: snapshot.catalog) {
            actions.append(CodeAction(title: expansion.title, kind: "refactor.rewrite",
                                      edits: [edit(expansion.range, replacement: expansion.newText)]))
        }
        guard diagnostics.contains(where: { $0.source == "SQL" && $0.range.start.line == position.line }) else {
            return actions
        }
        for finding in SQLDiagnosticsEngine.diagnose(text: text, dialect: dialect, catalog: snapshot.catalog) {
            guard SQLDiagnosticProvider.position(finding.range.location, lineStarts).line == localPosition.line else { continue }
            for fix in finding.fixes {
                actions.append(CodeAction(title: fix.title, kind: "quickfix",
                                          edits: [edit(fix.range, replacement: fix.replacement)]))
            }
        }
        return actions
    }
}

struct SQLNavigationProvider: NavigationProvider {
    let name = "SQL"
    let store: SQLSnapshotStore

    func isPrimary(for context: NavigationContext) -> Bool {
        context.kind == .definition && context.document.languageIdentifier == "sql"
            && store.snapshot(for: context.document.id) != nil
    }

    func provide(context: NavigationContext) async -> NavigationResult? {
        let document = context.document
        guard isPrimary(for: context), let snapshot = store.snapshot(for: document.id),
              let dialect = snapshot.dialect else { return nil }
        let caret = context.cursor.position.utf16Offset
        let (text, start) = SQLWindow.around(caret, in: document)
        guard let target = SQLAssist.declaration(text: text, caret: caret - start, dialect: dialect, catalog: snapshot.catalog)
        else { return nil }
        switch target {
        case .local(let range):
            // The navigation controller already materializes the buffer off the main actor.
            let starts = SQLDiagnosticProvider.lineStarts(document.text)
            let lower = SQLDiagnosticProvider.position(start + range.location, starts)
            let upper = SQLDiagnosticProvider.position(start + NSMaxRange(range), starts)
            return .single(Location(documentID: document.id, url: document.url,
                                    range: TextRange(start: lower, end: upper),
                                    displayName: (text as NSString).substring(with: range)))
        case .relation(let name), .column(let name, _):
            let column: String?
            if case .column(_, let field) = target { column = field } else { column = nil }
            let position = context.cursor.position
            return .single(Location(documentID: document.id, range: TextRange(start: position, end: position),
                                    displayName: column.map { "\(name).\($0)" } ?? name,
                                    target: .databaseRelation(name: name, column: column)))
        }
    }
}
