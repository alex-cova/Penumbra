import EditorIntelligence
import Foundation

/// Completion inside the string of Spring annotations whose values are names the project defines:
/// `@Qualifier("…")`, `@Named("…")` and `@Resource(name = "…")` offer bean names and qualifiers (narrowed
/// to beans assignable to the annotated injection point when it is known); `@Profile("…")` offers the
/// profiles the project declares or has `application-<profile>` files for.
public struct SpringCompletionProvider: CompletionProvider {
    public let name = "spring"
    private let indexer: SpringWorkspaceIndexer

    public init(indexer: SpringWorkspaceIndexer) { self.indexer = indexer }

    enum Site: Equatable { case beanName, profile, pathVariable, mediaType }

    /// The annotation string the caret is inside, and the UTF-16 offset where its content starts.
    static func site(in text: String, caretUTF16: Int) -> (site: Site, contentStart: Int)? {
        let ns = text as NSString
        guard caretUTF16 <= ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: caretUTF16, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: caretUTF16 - lineStart))
        let whole0 = NSRange(location: 0, length: (before as NSString).length)
        if let r = try? NSRegularExpression(pattern: #"@(?:[A-Za-z_]\w*\.)*PathVariable\s*\(\s*(?:(?:name|value)\s*=\s*)?"([^"]*)$"#),
           let m = r.firstMatch(in: before, range: whole0) { return (.pathVariable, lineStart + m.range(at: 1).location) }
        if let r = try? NSRegularExpression(pattern: #"\b(?:produces|consumes)\s*=\s*(?:\{[^}"]*(?:"[^"]*"\s*,\s*)*)?"([^"]*)$"#),
           let m = r.firstMatch(in: before, range: whole0) { return (.mediaType, lineStart + m.range(at: 1).location) }
        guard let regex = try? NSRegularExpression(
            pattern: #"@(?:[A-Za-z_][\w]*\.)*(Qualifier|Named|Resource|Profile)\s*\(\s*(?:name\s*=\s*|value\s*=\s*)?"([^"]*)$"#) else { return nil }
        let whole = NSRange(location: 0, length: (before as NSString).length)
        guard let m = regex.firstMatch(in: before, range: whole) else { return nil }
        let annotation = (before as NSString).substring(with: m.range(at: 1))
        let content = m.range(at: 2)
        return (annotation == "Profile" ? .profile : .beanName, lineStart + content.location)
    }

    public func provide(context: CompletionContext) async -> [CompletionItem] {
        let doc = context.document
        guard doc.languageIdentifier == "java", let url = doc.url?.standardizedFileURL else { return [] }
        let text = doc.text
        let caret = context.cursor.position.utf16Offset
        // Cheap textual check first: this runs on every Java completion, in the same tier as Java's own.
        guard let (site, start) = Self.site(in: text, caretUTF16: caret), await indexer.contains(url) else { return [] }
        await indexer.ingest(url: url, text: text)
        let model = await indexer.store.model(for: url)
        let ns = text as NSString
        let typed = ns.substring(with: NSRange(location: start, length: caret - start))
        let ranges = SpringTextRanges(text: text)
        func utf16Position(_ offset: Int) -> TextPosition {
            // Convert via the byte offset so line/column are computed the way diagnostics are.
            let prefix = ns.substring(to: offset)
            return ranges.position(prefix.utf8.count)
        }
        let replace = EditorIntelligence.TextRange(start: utf16Position(start), end: utf16Position(caret))

        var names: [(String, String?)] = []
        switch site {
        case .beanName:
            let byte = SpringNavigationProvider.byteOffset(utf16: caret, in: text)
            var pool: [SpringBean]
            if let point = model.injectionPoints.first(where: { $0.location.url == url && $0.location.byteRange.contains(byte) }),
               let ids = model.typeCandidates[point], !ids.isEmpty {
                pool = ids.compactMap(model.bean)
            } else {
                pool = model.beans.filter { !$0.certainty.isInactive }
            }
            var seen = Set<String>()
            for b in pool {
                for n in [b.name] + b.qualifiers where seen.insert(n).inserted { names.append((n, b.type.simpleName)) }
            }
        case .mediaType:
            names = ["application/json", "application/xml", "application/x-www-form-urlencoded", "multipart/form-data", "text/plain",
                     "text/html", "text/event-stream", "application/x-ndjson", "application/octet-stream", "application/problem+json",
                     "application/pdf"].map { ($0, nil) }
        case .pathVariable:
            let byte = SpringNavigationProvider.byteOffset(utf16: caret, in: text)
            let bytes = Array(text.utf8)
            let handlers = await indexer.store.endpointIndexes(containing: url).flatMap { $0.endpoints(in: url) }
                .filter { $0.handlerLocation.url == url && $0.handlerLocation.byteRange.lowerBound <= byte }
            guard let nearest = handlers.map(\.handlerLocation.byteRange.lowerBound).max(), nearest < byte,
                  !bytes[nearest..<min(byte, bytes.count)].contains(0x7B) else { break }   // still in the parameter list
            var seen = Set<String>()
            for e in handlers where e.handlerLocation.byteRange.lowerBound == nearest {
                for v in e.pathVariables where seen.insert(v).inserted { names.append((v, "in \(e.route)")) }
            }
        case .profile:
            var profiles = model.declaredProfiles
            for module in await indexer.modules {
                for root in module.resourceRoots {
                    for f in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
                        guard f.hasPrefix("application-") else { continue }
                        let stem = (f as NSString).deletingPathExtension.dropFirst("application-".count)
                        if !stem.isEmpty { profiles.insert(String(stem)) }
                    }
                }
            }
            names = profiles.sorted().map { ($0, nil) }
        }
        return names
            .filter { typed.isEmpty || $0.0.lowercased().hasPrefix(typed.lowercased()) || $0.0.lowercased().contains(typed.lowercased()) }
            .sorted { $0.0 < $1.0 }
            .map { CompletionItem(label: $0.0, insertText: $0.0, kind: .field, range: replace, source: "Spring", detail: $0.1) }
    }
}
