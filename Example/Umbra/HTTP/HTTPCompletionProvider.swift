import EditorIntelligence
import Foundation

/// Completion for `.http` files: `{{ }}` names and functions, methods, headers, auth, and `# @` flags.
/// Primary only at those sites, so a JSON body still gets ordinary word completion.
final class HTTPCompletionProvider: CompletionProvider, @unchecked Sendable {
    typealias GlobalsSource = @Sendable () -> [String: String]

    let name = "HTTP"

    private let lock = NSLock()
    private var globalsSource: GlobalsSource = { [:] }
    private var schemaStore: GraphQLSchemaStore?

    func setGlobals(_ source: @escaping GlobalsSource) {
        lock.lock()
        globalsSource = source
        lock.unlock()
    }

    /// Where GraphQL bodies get their schema. Without one, only the other sites complete.
    func setSchemaStore(_ store: GraphQLSchemaStore?) {
        lock.lock()
        schemaStore = store
        lock.unlock()
    }

    private var currentSchemaStore: GraphQLSchemaStore? {
        lock.lock()
        defer { lock.unlock() }
        return schemaStore
    }

    private var globals: [String: String] {
        lock.lock()
        let source = globalsSource
        lock.unlock()
        return source()
    }

    func isPrimary(for context: CompletionContext) -> Bool {
        guard context.document.languageIdentifier == "http" else { return false }
        return HTTPCompletion.site(in: context.document.text, caretUTF16: context.cursor.position.utf16Offset) != nil
    }

    func provide(context: CompletionContext) async -> [CompletionItem] {
        guard context.document.languageIdentifier == "http" else { return [] }
        let text = context.document.text
        let caret = context.cursor.position.utf16Offset
        guard let site = HTTPCompletion.site(in: text, caretUTF16: caret) else { return [] }
        switch site {
        case .template:
            return templateItems(in: text, caret: caret, range: context.range)
        case .method:
            return HTTPCompletion.methods.map {
                item($0, insert: $0 + " ", kind: .keyword, range: context.range, filter: $0)
            }
        case .headerName:
            return HTTPCompletion.headerNames.map {
                item($0, insert: $0 + ": ", kind: .keyword, range: context.range, filter: $0)
            }
        case .authorization:
            return HTTPCompletion.authorizationSchemes.map {
                item($0, insert: $0 + " ", kind: .keyword, range: context.range, filter: $0)
            }
        case .mediaType:
            return HTTPCompletion.mediaTypes.map {
                item($0, insert: $0, kind: .keyword, range: context.range, filter: $0)
            }
        case .directive:
            return HTTPCompletion.flags.map {
                item($0, insert: $0, kind: .keyword, range: context.range, filter: $0)
            }
        case .graphQL:
            return await graphQLItems(in: text, caret: caret, context: context)
        }
    }

    /// Reads the schema the file names without waiting for the network: a schema that is not here yet
    /// is being fetched, and the next keystroke finds it.
    private func graphQLItems(in text: String, caret: Int, context: CompletionContext) async -> [CompletionItem] {
        guard let store = currentSchemaStore,
              let directive = HTTPGraphQLDirective.directive(in: text, caretUTF16: caret),
              let body = HTTPCompletion.graphQLBody(in: text, caretUTF16: caret),
              case .success(let request) = GraphQLSchemaResolver.resolve(
                  directive, in: text, fileURL: context.document.url, globals: globals
              ),
              let schema = await store.schema(for: request),
              let site = GraphQLCompletionContext.site(in: body, schema: schema) else {
            return []
        }
        return GraphQLCompletionItems.items(for: site, schema: schema, range: context.range, source: name)
    }

    private func templateItems(in text: String, caret: Int, range: EditorIntelligence.TextRange) -> [CompletionItem] {
        var items: [CompletionItem] = HTTPCompletion.functions.map { function in
            let insert = HTTPCompletion.insertion(function.insert, in: text, caretUTF16: caret)
            let caretOffset = function.insert.hasSuffix("()") ? (function.insert as NSString).length - 1 : nil
            return item(
                function.label,
                insert: insert,
                kind: .function,
                range: range,
                filter: function.filter,
                detail: function.detail,
                labelDetail: function.labelDetail,
                priority: 2,
                caretOffset: caretOffset
            )
        }
        let fileVariables = HTTPSyntax.fileVariables(in: text)
        var seen = Set(fileVariables.keys)
        for name in fileVariables.keys.sorted() {
            guard let value = fileVariables[name] else { continue }
            items.append(variable(name, value: value, in: text, caret: caret, range: range, priority: 1))
        }
        for name in globals.keys.sorted() where !seen.contains(name) && !name.hasPrefix("$") {
            seen.insert(name)
            items.append(variable(name, value: globals[name] ?? "", in: text, caret: caret, range: range, priority: 0))
        }
        return items
    }

    private func variable(
        _ name: String,
        value: String,
        in text: String,
        caret: Int,
        range: EditorIntelligence.TextRange,
        priority: Double
    ) -> CompletionItem {
        item(
            name,
            insert: HTTPCompletion.insertion(name, in: text, caretUTF16: caret),
            kind: .variable,
            range: range,
            filter: name,
            detail: HTTPCompletion.preview(value),
            priority: priority
        )
    }

    private func item(
        _ label: String,
        insert: String,
        kind: CompletionItemKind,
        range: EditorIntelligence.TextRange,
        filter: String,
        detail: String? = nil,
        labelDetail: String? = nil,
        priority: Double = 0,
        caretOffset: Int? = nil
    ) -> CompletionItem {
        CompletionItem(
            label: label,
            insertText: insert,
            kind: kind,
            range: range,
            source: name,
            filterText: filter,
            detail: detail,
            labelDetail: labelDetail,
            priority: priority,
            caretOffset: caretOffset
        )
    }
}

enum HTTPCompletion {
    enum Site: Equatable {
        case template
        case method
        case headerName
        case authorization
        case mediaType
        case directive
        /// In a GraphQL body of a file that names a `###@scheme:`.
        case graphQL
    }

    struct Function {
        var label: String
        var filter: String
        var insert: String
        var labelDetail: String?
        var detail: String?
    }

    static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
    static let headerNames = [
        "Accept", "Authorization", "Cache-Control", "Content-Type", "Cookie", "Host", "User-Agent",
    ]
    static let authorizationSchemes = ["Basic", "Bearer", "Digest"]
    static let mediaTypes = [
        "application/json",
        "application/xml",
        "application/x-www-form-urlencoded",
        "multipart/form-data",
        "text/plain",
        "text/html",
        "application/octet-stream",
    ]
    static let flags = ["no-redirect", "no-cookie-jar", "no-auto-encoding"]

    static let functions: [Function] = [
        Function(label: "$uuid", filter: "$uuid", insert: "$uuid", detail: "uuid"),
        Function(label: "$timestamp", filter: "$timestamp", insert: "$timestamp", detail: "unix seconds"),
        Function(label: "$isoTimestamp", filter: "$isoTimestamp", insert: "$isoTimestamp", detail: "iso-8601"),
        Function(label: "$randomInt", filter: "$randomInt", insert: "$randomInt", detail: "0…1000"),
        Function(label: "$random.uuid", filter: "$random.uuid", insert: "$random.uuid", detail: "uuid"),
        Function(label: "$random.integer", filter: "$random.integer()", insert: "$random.integer()", labelDetail: "(from, to)", detail: "0…1000"),
        Function(label: "$random.float", filter: "$random.float()", insert: "$random.float()", labelDetail: "(from, to)", detail: "0…1"),
        Function(label: "$random.alphabetic", filter: "$random.alphabetic()", insert: "$random.alphabetic()", labelDetail: "(length)"),
        Function(label: "$random.alphanumeric", filter: "$random.alphanumeric()", insert: "$random.alphanumeric()", labelDetail: "(length)"),
        Function(label: "$random.hexadecimal", filter: "$random.hexadecimal()", insert: "$random.hexadecimal()", labelDetail: "(length)"),
        Function(label: "$random.email", filter: "$random.email", insert: "$random.email"),
        Function(label: "$historyFolder", filter: "$historyFolder", insert: "$historyFolder", detail: "response folder"),
    ]

    static func site(in text: String, caretUTF16: Int) -> Site? {
        let ns = text as NSString
        let caret = min(max(caretUTF16, 0), ns.length)
        let before = ns.substring(to: caret)
        let tokenStart = CompletionTokenScan.tokenStart(utf16Text: before, caret: (before as NSString).length)
        if CompletionTokenScan.opensTemplate(utf16Text: before, tokenStart: tokenStart) {
            return .template
        }

        let breakRange = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: caret))
        let lineStart = breakRange.location == NSNotFound ? 0 : breakRange.location + breakRange.length
        var linePrefix = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        if linePrefix.hasSuffix("\r") {
            linePrefix.removeLast()
        }
        let previous = lineStart == 0 ? "" : ns.substring(to: lineStart)
        let scanned = scan(before: previous)
        let region = scanned.region

        if directivePrefix(linePrefix) {
            return .directive
        }
        if region == .headers, let field = headerField(linePrefix), valueTokenIsOpen(field.value) {
            switch field.name.lowercased() {
            case "authorization":
                return .authorization
            case "accept", "content-type":
                return field.value.contains("/") ? nil : .mediaType
            default:
                return nil
            }
        }

        if region == .body {
            return graphQLBody(in: text, caretUTF16: caret) != nil ? .graphQL : nil
        }

        let token = firstToken(in: linePrefix)
        guard !token.closed else { return nil }
        switch region {
        case .headers where isHeaderToken(token.text):
            return .headerName
        case .betweenRequests where isMethodToken(token.text):
            return .method
        default:
            return nil
        }
    }

    /// `}}` is added only when the token is not already closed and the call is not already open.
    static func insertion(_ token: String, in text: String, caretUTF16: Int) -> String {
        let ns = text as NSString
        let caret = min(max(caretUTF16, 0), ns.length)
        let rest = ns.substring(from: caret)
        var index = 0
        let restNS = rest as NSString
        while index < restNS.length {
            let unit = restNS.character(at: index)
            guard let scalar = UnicodeScalar(unit) else { break }
            if isCompletionIdentifierScalar(scalar) || scalar == "." {
                index += 1
                continue
            }
            break
        }
        let after = restNS.substring(from: index)
        if after.hasPrefix("}}") || after.hasPrefix("(") {
            return token
        }
        return token + "}}"
    }

    static func preview(_ value: String) -> String {
        let singleLine = value.replacingOccurrences(of: "\n", with: " ")
        guard singleLine.count > 40 else { return singleLine }
        return String(singleLine.prefix(40)) + "…"
    }

    private enum Region {
        case betweenRequests
        case headers
        case body
    }

    private struct Scan {
        var region: Region
        /// UTF-16 offset of the body's first line, while `region` is `.body`.
        var bodyStart: Int?
        /// The method of the request the body belongs to.
        var method: String?
    }

    /// The text of the GraphQL body before the caret when the caret is in one and the file names a
    /// schema for it: the request is a `GRAPHQL` one or the body starts like an operation. The
    /// variables object after the operation is JSON and answers nil from the analysis itself.
    static func graphQLBody(in text: String, caretUTF16: Int) -> String? {
        let ns = text as NSString
        let caret = min(max(caretUTF16, 0), ns.length)
        guard HTTPGraphQLDirective.directive(in: text, caretUTF16: caret) != nil else { return nil }
        let breakRange = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: caret))
        let lineStart = breakRange.location == NSNotFound ? 0 : breakRange.location + breakRange.length
        let scanned = scan(before: lineStart == 0 ? "" : ns.substring(to: lineStart))
        guard scanned.region == .body else { return nil }
        // No body line before this one: the caret's own line is where the body starts.
        let start = scanned.bodyStart ?? lineStart
        guard start <= caret else { return nil }
        let body = ns.substring(with: NSRange(location: start, length: caret - start))
        if scanned.method == "GRAPHQL" {
            return body
        }
        let tokens = GraphQLLexer.lex(body).tokens
        guard let first = tokens.first else {
            // Nothing typed yet: a body without a method that says GraphQL could be anything.
            return nil
        }
        if first.kind == .name, ["query", "mutation", "subscription", "fragment"].contains(first.text) {
            return body
        }
        if first.isPunctuator("{"), tokens.count < 2 || tokens[1].kind != .string {
            return body
        }
        return nil
    }

    /// Walks the lines before the caret's line and says where the caret's line belongs. The caret's
    /// own line is not part of `text`, so a trailing line break is the break before that line.
    private static func scan(before text: String) -> Scan {
        var scan = Scan(region: .betweenRequests, bodyStart: nil, method: nil)
        var depth = 0
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { substring, range, _, _ in
            let line = substring ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if scan.region == .headers {
                    scan.region = .body
                    scan.bodyStart = nil
                }
                return
            }
            if trimmed.hasPrefix("###") {
                scan.region = .betweenRequests
                scan.bodyStart = nil
                depth = 0
                return
            }
            if HTTPSyntax.isDirectiveLine(line) {
                scan.region = .betweenRequests
                scan.bodyStart = nil
                depth = 0
                return
            }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") || trimmed.hasPrefix("@") {
                return
            }
            // A request line starts a request, except inside a body that is still open: a GraphQL
            // string value or a JSON text may begin like one.
            let insideOpenBody = scan.region == .body && scan.bodyStart != nil && depth > 0
            if HTTPSyntax.isRequestLine(line), !insideOpenBody {
                scan.region = .headers
                scan.bodyStart = nil
                scan.method = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
                depth = 0
                return
            }
            if scan.region == .headers, headerField(line) != nil {
                return
            }
            scan.region = .body
            if scan.bodyStart == nil {
                scan.bodyStart = range.location
                depth = 0
            }
            depth += braceBalance(of: trimmed)
            // The closing brace of a body ends it, so the next line may be a request again. Braces
            // that close something opened inside the body (a nested object, a selection set) do not.
            if (trimmed == "}" || trimmed == "]"), depth <= 0 {
                scan.region = .betweenRequests
                scan.bodyStart = nil
                depth = 0
            }
        }
        return scan
    }

    /// Opening minus closing brackets on a line, outside strings and `#` comments.
    private static func braceBalance(of line: String) -> Int {
        var balance = 0
        var inString = false
        var escaped = false
        for character in line {
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"": inString = true
            case "#": return balance
            case "{", "[": balance += 1
            case "}", "]": balance -= 1
            default: break
            }
        }
        return balance
    }

    private struct Token {
        var text: String
        var closed: Bool
    }

    private static func firstToken(in linePrefix: String) -> Token {
        var index = linePrefix.startIndex
        while index < linePrefix.endIndex, linePrefix[index] == " " || linePrefix[index] == "\t" {
            index = linePrefix.index(after: index)
        }
        let tokenStart = index
        while index < linePrefix.endIndex, linePrefix[index] != " ", linePrefix[index] != "\t" {
            index = linePrefix.index(after: index)
        }
        return Token(text: String(linePrefix[tokenStart..<index]), closed: index < linePrefix.endIndex)
    }

    private static func isMethodToken(_ token: String) -> Bool {
        if token.isEmpty { return true }
        if token.lowercased().hasPrefix("http") { return false }
        return token.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    private static func isHeaderToken(_ token: String) -> Bool {
        if token.isEmpty { return true }
        return token.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || $0 == "-" }
    }

    private static func directivePrefix(_ linePrefix: String) -> Bool {
        var text = linePrefix.drop(while: { $0 == " " || $0 == "\t" })
        if text.hasPrefix("//") {
            text = text.dropFirst(2)
        } else if text.hasPrefix("#") {
            text = text.dropFirst()
        } else {
            return false
        }
        text = text.drop(while: { $0 == " " || $0 == "\t" })
        return text.first == "@"
    }

    private static func headerField(_ line: String) -> (name: String, value: String)? {
        let indentEnd = line.firstIndex(where: { $0 != " " && $0 != "\t" }) ?? line.endIndex
        let rest = line[indentEnd...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let name = rest[..<colon].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0 == "-" }) else { return nil }
        return (name, String(rest[rest.index(after: colon)...]))
    }

    private static func valueTokenIsOpen(_ value: String) -> Bool {
        let rest = value.drop(while: { $0 == " " || $0 == "\t" })
        return !rest.contains(where: { $0 == " " || $0 == "\t" })
    }
}
