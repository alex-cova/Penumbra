import EditorIntelligence
import Foundation

/// Quick fixes for Spring injection problems in the current file. Every fix is an ordinary edit the
/// user sees and applies; none changes wiring on its own. Fixes that would edit another file (annotating
/// a candidate `@Primary`, registering a bean) are not offered here because a `CodeAction` edits one document.
public struct SpringCodeActionProvider: CodeActionProviding {
    private let indexer: SpringWorkspaceIndexer
    private static let qualifierName = "org.springframework.beans.factory.annotation.Qualifier"

    public init(indexer: SpringWorkspaceIndexer) { self.indexer = indexer }

    public func codeActions(for document: Document, at position: TextPosition, diagnostics: [Diagnostic]) async -> [CodeAction] {
        guard document.languageIdentifier == "java", let url = document.url?.standardizedFileURL,
              await indexer.contains(url) else { return [] }
        let text = document.text
        await indexer.ingest(url: url, text: text)
        let model = await indexer.store.model(for: url)
        let byte = SpringNavigationProvider.byteOffset(utf16: position.utf16Offset, in: text)
        let ranges = SpringTextRanges(text: text)
        let usesShortQualifier = Self.importsQualifier(text)
        var actions: [CodeAction] = []
        var textCache: [URL: String] = [url: text]
        func insertionPlan(title: String, url target: URL, atByte offset: Int, annotation: String, note: String) -> CodeAction? {
            if textCache[target] == nil { textCache[target] = try? String(contentsOf: target, encoding: .utf8) }
            guard let targetText = textCache[target] else { return nil }
            let r = SpringTextRanges(text: targetText)
            let at = r.position(offset)
            let lineStart = (targetText as NSString).lineRange(for: NSRange(location: at.utf16Offset, length: 0))
            let line = (targetText as NSString).substring(with: lineStart).trimmingCharacters(in: .newlines)
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let entry = WorkspaceEditPlanEntry(
                url: target, range: EditorIntelligence.TextRange(start: at, end: at), oldText: "",
                newText: annotation + "\n" + indent, lineText: line, description: note)
            return CodeAction(title: title, kind: "quickfix", edits: [], preview: note,
                              workspacePlan: WorkspaceEditPlan(entries: [entry], title: title))
        }
        for point in model.injectionPoints where point.location.url == url && point.location.byteRange.contains(byte) {
            switch model.resolutions[point] {
            case .ambiguous(let ids)?:
                for bean in ids.compactMap(model.bean) {
                    if let primary = insertionPlan(
                        title: "Make \(bean.name) the @Primary \(point.requiredType.simpleName) bean", url: bean.location.url,
                        atByte: bean.declarationStart, annotation: "@org.springframework.context.annotation.Primary",
                        note: "Every injection point of this type without a qualifier will now receive '\(bean.name)'. Review the other consumers.") {
                        actions.append(primary)
                    }
                    let annotation = "@\(usesShortQualifier ? "Qualifier" : Self.qualifierName)(\"\(bean.name)\") "
                    let at = ranges.position(point.annotationInsertOffset)
                    actions.append(CodeAction(
                        title: "Add @Qualifier(\"\(bean.name)\") to select \(bean.type.simpleName) bean",
                        kind: "quickfix",
                        edits: [TextEdit(range: EditorIntelligence.TextRange(start: at, end: at), replacement: annotation)],
                        preview: "Injects the bean named '\(bean.name)'. Other candidates are no longer used here."))
                }
            case .unknownQualifier(let wrong)?:
                guard let qRange = point.qualifierRange else { continue }
                let written = Self.annotationName(in: text, byteRange: qRange) ?? "Qualifier"
                for id in model.typeCandidates[point] ?? [] {
                    guard let bean = model.bean(id) else { continue }
                    actions.append(CodeAction(
                        title: "Change qualifier '\(wrong)' to '\(bean.name)'", kind: "quickfix",
                        edits: [TextEdit(range: ranges.range(qRange), replacement: "@\(written)(\"\(bean.name)\")")],
                        preview: "Replaces the qualifier with the name of an existing \(point.requiredType.simpleName) bean."))
                }
            case .missing?:
                for candidate in (model.unregistered[point] ?? []).prefix(3) {
                    let simple = candidate.typeName.split(separator: ".").last.map(String.init) ?? candidate.typeName
                    if let fix = insertionPlan(
                        title: "Register \(simple) as a Spring bean (@Component)", url: candidate.location.url,
                        atByte: candidate.declarationStart, annotation: "@org.springframework.stereotype.Component",
                        note: "\(simple) implements \(point.requiredType.simpleName) but is not a bean. Registering it makes it injectable everywhere.") {
                        actions.append(fix)
                    }
                }
            default:
                continue
            }
        }
        actions += await endpointFixes(url: url, text: text, byte: byte, ranges: ranges)
        return actions
    }

    /// Fixes for mapping problems under the caret. Each is a single edit in this file.
    private func endpointFixes(url: URL, text: String, byte: Int, ranges: SpringTextRanges) async -> [CodeAction] {
        var out: [CodeAction] = []
        let bytes = Array(text.utf8)
        for d in await SpringDiagnosticProvider.diagnostics(in: indexer.store, url: url)
        where d.location.url == url && (d.location.byteRange.contains(byte) || d.location.byteRange.upperBound == byte) {
            switch d.code {
            case SpringEndpointDiagnosticCode.unknownPathVariable:
                guard let name = d.suggestion, d.location.byteRange.upperBound <= bytes.count else { continue }
                let param = String(decoding: bytes[d.location.byteRange], as: UTF8.self)
                guard let regex = try? NSRegularExpression(pattern: #"@((?:[A-Za-z_]\w*\.)*PathVariable)(\s*\([^)]*\))?"#),
                      let m = regex.firstMatch(in: param, range: NSRange(location: 0, length: (param as NSString).length)) else { continue }
                let args = m.range(at: 2).location == NSNotFound ? "" : (param as NSString).substring(with: m.range(at: 2))
                guard !args.contains("required"), !args.contains("defaultValue") else { continue }
                let written = (param as NSString).substring(with: m.range(at: 1))
                let before = (param as NSString).substring(to: m.range.location).utf8.count
                let length = (param as NSString).substring(with: m.range).utf8.count
                let start = d.location.byteRange.lowerBound + before
                out.append(CodeAction(
                    title: "Bind to path variable {\(name)}", kind: "quickfix",
                    edits: [TextEdit(range: ranges.range(start..<(start + length)), replacement: "@\(written)(\"\(name)\")")],
                    preview: "The mapping declares {\(name)} and no other parameter reads it."))
            case SpringEndpointDiagnosticCode.multipleMappings:
                var end = d.location.byteRange.upperBound
                while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
                if end < bytes.count, bytes[end] == 0x0A { end += 1 }
                let name = String(decoding: bytes[d.location.byteRange], as: UTF8.self).prefix { $0 != "(" }
                out.append(CodeAction(
                    title: "Remove the ignored \(name)", kind: "quickfix",
                    edits: [TextEdit(range: ranges.range(d.location.byteRange.lowerBound..<end), replacement: "")],
                    preview: "Spring only reads the first mapping annotation, so this one never had an effect."))
            default:
                continue
            }
        }
        return out
    }

    static func importsQualifier(_ text: String) -> Bool {
        text.contains("import \(qualifierName);") || text.contains("import org.springframework.beans.factory.annotation.*;")
    }

    private static func annotationName(in text: String, byteRange: Range<Int>) -> String? {
        let bytes = Array(text.utf8)
        guard byteRange.upperBound <= bytes.count else { return nil }
        let s = String(decoding: bytes[byteRange], as: UTF8.self)
        guard s.hasPrefix("@"), let paren = s.firstIndex(of: "(") else { return nil }
        return String(s[s.index(after: s.startIndex)..<paren]).trimmingCharacters(in: .whitespaces)
    }
}
