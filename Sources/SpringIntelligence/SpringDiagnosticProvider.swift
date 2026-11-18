import EditorIntelligence
import Foundation

/// Spring injection and bean diagnostics for one Java document, from the shared ``SpringModel``.
///
/// Only files inside a detected Spring module are touched, so other Java files cost one set lookup.
/// The document's own text is ingested first, so unsaved edits are what gets analysed.
public struct SpringDiagnosticProvider: DiagnosticProvider {
    public let name = "spring"
    private let indexer: SpringWorkspaceIndexer

    public init(indexer: SpringWorkspaceIndexer) { self.indexer = indexer }

    public func diagnostics(for document: Document) async -> [Diagnostic] {
        guard document.languageIdentifier == "java", let url = document.url?.standardizedFileURL,
              await indexer.contains(url) else { return [] }
        let text = document.text
        await indexer.ingest(url: url, text: text)
        if Task.isCancelled { return [] }
        let mine = await Self.diagnostics(in: indexer.store, url: url)
        guard !mine.isEmpty else { return [] }
        let ranges = SpringTextRanges(text: text)
        return mine.map { d in
            Diagnostic(
                severity: { switch d.severity { case .error: .error; case .warning: .warning; case .info: .information } }(),
                message: d.message, range: ranges.range(d.location.byteRange), source: "Spring", code: d.code)
        }
    }
}

extension SpringDiagnosticProvider {
    /// A file shared by several applications is judged by each of them. A problem every one of them has is a problem;
    /// one only some have depends on the application, so it is reported as a warning naming them (a bean the file
    /// needs may be provided by another application's configuration).
    static func diagnostics(in store: SpringProjectModel, url: URL) async -> [SpringDiagnostic] {
        let contexts = await store.contexts(containing: url)
        guard !contexts.isEmpty else { return [] }
        struct Key: Hashable { let code: String; let range: Range<Int>; let message: String }
        var seen: [Key: (SpringDiagnostic, [String])] = [:]
        var order: [Key] = []
        let indexes = await store.endpointIndexes()
        for context in contexts {
            let own = context.model.diagnostics.filter { $0.location.url == url }
            for d in own + (indexes.first { $0.contextID == context.id }?.diagnostics(in: url) ?? []) {
                let key = Key(code: d.code, range: d.location.byteRange, message: d.message)
                if seen[key] == nil { order.append(key); seen[key] = (d, [context.name]) } else { seen[key]!.1.append(context.name) }
            }
        }
        return order.compactMap { key in
            guard let (d, names) = seen[key] else { return nil }
            if names.count == contexts.count { return d }
            return SpringDiagnostic(severity: d.severity == .error ? .warning : d.severity, code: d.code,
                                    message: d.message + " (in \(names.sorted().joined(separator: ", ")) only)",
                                    location: d.location, related: d.related, suggestion: d.suggestion)
        }
    }
}

/// UTF-8 byte ranges to editor line/column/UTF-16 positions, in one pass over the text.
struct SpringTextRanges {
    private var lineStartsByte: [Int] = [0]
    private let text: String

    init(text: String) {
        self.text = text
        var offset = 0
        for byte in text.utf8 {
            offset += 1
            if byte == 0x0A { lineStartsByte.append(offset) }
        }
    }

    func range(_ bytes: Range<Int>) -> EditorIntelligence.TextRange { EditorIntelligence.TextRange(start: position(bytes.lowerBound), end: position(bytes.upperBound)) }

    func position(_ byte: Int) -> TextPosition {
        let utf8 = text.utf8
        let clamped = max(0, min(byte, utf8.count))
        var lo = 0, hi = lineStartsByte.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStartsByte[mid] <= clamped { lo = mid } else { hi = mid - 1 }
        }
        let lineStart = utf8.index(utf8.startIndex, offsetBy: lineStartsByte[lo])
        let here = utf8.index(utf8.startIndex, offsetBy: clamped)
        let column = text.utf16.distance(from: lineStart, to: here)
        let offset = text.utf16.distance(from: text.utf16.startIndex, to: here)
        return TextPosition(line: lo, column: column, utf16Offset: offset)
    }
}
