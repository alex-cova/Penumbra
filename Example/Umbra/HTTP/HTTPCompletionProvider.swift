import EditorIntelligence
import Foundation

/// Completion for `.http` files: `{{ }}` names and functions, methods, headers, auth, and `# @` flags.
/// Primary only at those sites, so a JSON body still gets ordinary word completion.
final class HTTPCompletionProvider: CompletionProvider, @unchecked Sendable {
    typealias GlobalsSource = @Sendable () -> [String: String]

    let name = "HTTP"

    private let lock = NSLock()
    private var globalsSource: GlobalsSource = { [:] }

    func setGlobals(_ source: @escaping GlobalsSource) {
        lock.lock()
        globalsSource = source
        lock.unlock()
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
        }
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
        let region = region(before: previous)

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

    private static func region(before text: String) -> Region {
        var region = Region.betweenRequests
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // The text is everything before the caret's line, so a trailing newline is the break
        // before that line, not a blank line of its own.
        var parts = normalized.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if normalized.hasSuffix("\n"), !parts.isEmpty {
            parts.removeLast()
        }
        for line in parts {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if region == .headers { region = .body }
                continue
            }
            if trimmed.hasPrefix("###") {
                region = .betweenRequests
                continue
            }
            if HTTPSyntax.isDirectiveLine(String(line)) || trimmed == "}" || trimmed == "]" {
                region = .betweenRequests
                continue
            }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") || trimmed.hasPrefix("@") {
                continue
            }
            if HTTPSyntax.isRequestLine(String(line)) {
                region = .headers
                continue
            }
            if region == .headers, headerField(String(line)) != nil {
                continue
            }
            region = .body
        }
        return region
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
