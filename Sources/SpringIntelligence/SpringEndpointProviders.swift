import EditorIntelligence
import Foundation

/// A place that calls an endpoint: an `.http` request line or a string in a test source that the route matches.
public struct SpringEndpointReference: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case httpRequest = "HTTP request", test = "Test request" }
    public let url: URL
    /// 0-based line and the UTF-16 column/length of the matching text.
    public let line: Int
    public let column: Int
    public let length: Int
    public let lineText: String
    public let kind: Kind
}

/// Finds requests to an endpoint in `.http` files and in test sources: the route pattern is matched against the path of each
/// request line or string literal (`/api/customers/{id}` matches `/api/customers/42`). Bounded: it reads at most `fileLimit`
/// candidate files, only those that contain the route's literal prefix, and returns at most `limit` hits.
public enum SpringEndpointReferences {
    private static let skipped: Set<String> = ["build", "out", "target", "node_modules", ".gradle", ".git", ".idea", "bin"]

    public static func find(endpoint: SpringEndpoint, roots: [URL], limit: Int = 100, fileLimit: Int = 2_000) -> [SpringEndpointReference] {
        let prefix = SpringRoute.literalPrefix(endpoint.route)
        let needle = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        guard needle.count >= 2, endpoint.confidence.isExact else { return [] }   // `/` alone would match every request
        let fm = FileManager.default
        var hits: [SpringEndpointReference] = []
        var visited = 0
        var seen = Set<URL>()
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            while let item = walker.nextObject() as? URL {
                if skipped.contains(item.lastPathComponent) { walker.skipDescendants(); continue }
                let ext = item.pathExtension
                let isHTTP = ext == "http"
                let isTest = ext == "java" && item.path.contains("/src/test/")
                guard isHTTP || isTest, seen.insert(item.standardizedFileURL).inserted else { continue }
                visited += 1
                if visited > fileLimit { return hits }
                guard let text = try? String(contentsOf: item, encoding: .utf8), text.contains(needle) else { continue }
                for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let line = String(raw)
                    guard line.contains(needle) else { continue }
                    if isHTTP {
                        if let r = httpRequest(in: line), matches(endpoint, path: r.path, method: r.method) {
                            hits.append(SpringEndpointReference(url: item.standardizedFileURL, line: index, column: r.column, length: r.length, lineText: line, kind: .httpRequest))
                        }
                    } else {
                        for literal in routeLiterals(in: line) where matches(endpoint, path: literal.path, method: literal.method) {
                            hits.append(SpringEndpointReference(url: item.standardizedFileURL, line: index, column: literal.column, length: literal.length, lineText: line, kind: .test))
                        }
                    }
                    if hits.count >= limit { return hits }
                }
            }
        }
        return hits
    }

    private static func matches(_ e: SpringEndpoint, path: String, method: String?) -> Bool {
        if let method, !e.conditions.methods.isEmpty, !e.conditions.methods.contains(method) { return false }
        return SpringRoute.matches(pattern: e.route, path: path)
    }

    // MARK: Reading requests

    /// The path (no scheme, host, query or fragment) of a URL or a path as written; `{{var}}` hosts are dropped.
    static func path(of url: String) -> String? {
        var s = url.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("{{"), let close = s.range(of: "}}") { s = String(s[close.upperBound...]) }
        else if let scheme = s.range(of: "://") {
            let rest = s[scheme.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return "/" }
            s = String(rest[slash...])
        }
        if let q = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<q]) }
        return s.hasPrefix("/") ? s : nil
    }

    struct Found { let path: String; let method: String?; let column: Int; let length: Int }

    /// `GET {{baseUrl}}/api/x HTTP/1.1`, or a bare URL line.
    static func httpRequest(in line: String) -> Found? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//"), !trimmed.hasPrefix("@") else { return nil }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return nil }
        let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
        let method = methods.contains(first) ? first : nil
        let urlText = method == nil ? first : (parts.count > 1 ? parts[1] : "")
        guard let path = path(of: urlText) else { return nil }
        let column = (line as NSString).range(of: urlText).location
        return Found(path: path, method: method, column: max(0, column), length: urlText.utf16.count)
    }

    /// String literals that look like request paths, with the HTTP method named just before them (`.get("/x")`, `post(…)`).
    static func routeLiterals(in line: String) -> [Found] {
        guard let literal = try? NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#),
              let verb = try? NSRegularExpression(pattern: #"(?i)\b(get|post|put|patch|delete)(?:ForObject|ForEntity|ForLocation|Mapping)?\s*\(\s*(?:[^()"]*,\s*)?$"#) else { return [] }
        let ns = line as NSString
        var out: [Found] = []
        for m in literal.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let content = m.range(at: 1)
            guard let path = path(of: ns.substring(with: content)) else { continue }
            let before = ns.substring(to: m.range.location)
            var method: String?
            if let v = verb.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) {
                method = (before as NSString).substring(with: v.range(at: 1)).uppercased()
            }
            out.append(Found(path: path, method: method, column: content.location, length: content.length))
        }
        return out
    }
}

/// Navigation that follows HTTP routes:
/// - from a request line in a `.http` file, or a route string in Java (a `MockMvc`/`WebTestClient` call, a client), to the handler;
/// - from a `${placeholder}` inside a mapping annotation to where that property is set (the configuration provider does the same
///   for `@Value`, and shares its site detection);
/// - Find Usages on a handler to the requests in `.http` files and tests that call it.
/// Types and symbols are never claimed: Go to Definition on Java code stays with Java.
public struct SpringEndpointNavigationProvider: NavigationProvider {
    public let name = "spring-endpoints"
    private let indexer: SpringWorkspaceIndexer
    public init(indexer: SpringWorkspaceIndexer) { self.indexer = indexer }

    public func provide(context: NavigationContext) async -> NavigationResult? {
        let doc = context.document
        guard await indexer.isActive else { return nil }
        let text = doc.text
        let caret = context.cursor.position.utf16Offset
        switch (doc.languageIdentifier, context.kind) {
        case ("http", .definition), ("http", .implementation):
            let ns = text as NSString
            guard caret <= ns.length else { return nil }
            let line = ns.substring(with: ns.lineRange(for: NSRange(location: caret, length: 0))).trimmingCharacters(in: .newlines)
            guard let request = SpringEndpointReferences.httpRequest(in: line) else { return nil }
            return await handlers(path: request.path, method: request.method, document: doc, text: text)
        case ("java", .definition), ("java", .implementation):
            guard let url = doc.url?.standardizedFileURL, await indexer.contains(url) else { return nil }
            let ns = text as NSString
            guard caret <= ns.length else { return nil }
            let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
            let line = ns.substring(with: lineRange)
            let caretInLine = caret - lineRange.location
            guard let literal = SpringEndpointReferences.routeLiterals(in: line).first(where: { caretInLine >= $0.column && caretInLine <= $0.column + $0.length }) else { return nil }
            await indexer.ingest(url: url, text: text)
            let byte = SpringNavigationProvider.byteOffset(utf16: caret, in: text)
            // A route inside a mapping annotation is the declaration itself, not a call to it.
            for index in await indexer.store.endpointIndexes() where !index.endpoints(in: url, atByte: byte).isEmpty { return nil }
            return await handlers(path: literal.path, method: literal.method, document: doc, text: text)
        case ("java", .references):
            guard let url = doc.url?.standardizedFileURL, await indexer.contains(url) else { return nil }
            await indexer.ingest(url: url, text: text)
            let byte = SpringNavigationProvider.byteOffset(utf16: caret, in: text)
            var handler: SpringEndpoint?
            for index in await indexer.store.endpointIndexes() {
                handler = index.endpoints(in: url, atByte: byte).first { $0.handlerLocation.url == url && ($0.handlerLocation.byteRange.contains(byte) || $0.handlerLocation.byteRange.upperBound == byte) }
                if handler != nil { break }
            }
            guard let handler else { return nil }
            let roots = await indexer.modules.filter(\.isSpring).map(\.directory)
            let hits = await Task.detached(priority: .userInitiated) { SpringEndpointReferences.find(endpoint: handler, roots: roots) }.value
            return Self.result(hits)
        default:
            return nil
        }
    }

    private func handlers(path: String, method: String?, document: Document, text: String) async -> NavigationResult? {
        var found: [SpringEndpoint] = []
        for index in await indexer.store.endpointIndexes() { found += index.endpoints(matchingPath: path, method: method) }
        var seen = Set<String>()
        found = found.filter { seen.insert("\($0.controller)#\($0.handlerSignature)").inserted }
        var cache: [URL: SpringTextRanges] = [:]
        let locations: [Location] = found.compactMap { e in
            let url = e.handlerLocation.url
            if cache[url] == nil, let t = try? String(contentsOf: url, encoding: .utf8) { cache[url] = SpringTextRanges(text: t) }
            guard let ranges = cache[url] else { return nil }
            return Location(documentID: DocumentID(), url: url, range: ranges.range(e.handlerLocation.byteRange), displayName: "\(e.title) — \(e.handlerTitle)")
        }
        switch locations.count {
        case 0: return nil
        case 1: return .single(locations[0])
        default: return .multiple(locations)
        }
    }

    static func result(_ hits: [SpringEndpointReference]) -> NavigationResult? {
        let locations: [Location] = hits.map { hit in
            let start = TextPosition(line: hit.line, column: hit.column, utf16Offset: 0)
            let end = TextPosition(line: hit.line, column: hit.column + hit.length, utf16Offset: 0)
            return Location(
                documentID: DocumentID(), url: hit.url, range: EditorIntelligence.TextRange(start: start, end: end),
                displayName: hit.url.lastPathComponent,
                usage: .init(kindLabel: hit.kind.rawValue, isAmbiguous: false, lineText: hit.lineText,
                             matchRange: NSRange(location: hit.column, length: max(1, hit.length)), line: hit.line))
        }
        switch locations.count {
        case 0: return nil
        case 1: return .single(locations[0])
        default: return .multiple(locations)
        }
    }
}

/// Endpoint navigation for `.http` files. Semantic tier like the other Spring services, so a route in a request line leads to its
/// handler before the generic providers answer; everywhere else it returns nil.
public struct SpringHTTPLanguageService: LanguageService {
    public let name = "umbra.spring-http"
    public let languageIdentifiers: Set<String> = ["http"]
    public let providers: LanguageProviders
    public let policy = LanguagePolicy.none
    public var tier: LanguageServiceTier { .semantic }

    public static func make(indexer: SpringWorkspaceIndexer) -> SpringHTTPLanguageService {
        SpringHTTPLanguageService(providers: LanguageProviders(navigation: [SpringEndpointNavigationProvider(indexer: indexer)]))
    }
}
