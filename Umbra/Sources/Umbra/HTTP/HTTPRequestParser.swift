import Foundation
import TreeSitter
import TreeSitterHTTP

/// Minimal tree-sitter wrapper for HTTP request parsing. Lives in the Umbra target with the `.http` runner.
final class HTTPTSyntaxTree: @unchecked Sendable {
    let sourceBytes: [UInt8]
    private let tree: OpaquePointer

    fileprivate init(tree: OpaquePointer, sourceBytes: [UInt8]) {
        self.tree = tree
        self.sourceBytes = sourceBytes
    }

    deinit {
        ts_tree_delete(tree)
    }

    var rootNode: HTTPTSyntaxNode {
        HTTPTSyntaxNode(raw: ts_tree_root_node(tree), tree: self)
    }

    func text(in range: Range<Int>) -> String {
        guard range.lowerBound >= 0, range.upperBound <= sourceBytes.count, range.lowerBound <= range.upperBound else {
            return ""
        }
        return String(decoding: sourceBytes[range], as: UTF8.self)
    }
}

struct HTTPTSyntaxNode {
    private let raw: TSNode
    let tree: HTTPTSyntaxTree

    init(raw: TSNode, tree: HTTPTSyntaxTree) {
        self.raw = raw
        self.tree = tree
    }

    var type: String {
        String(cString: ts_node_type(raw))
    }

    var startByte: Int { Int(ts_node_start_byte(raw)) }
    var endByte: Int { Int(ts_node_end_byte(raw)) }
    var byteRange: Range<Int> { startByte..<endByte }

    var text: String {
        tree.text(in: byteRange)
    }

    var childCount: Int { Int(ts_node_child_count(raw)) }
    var namedChildCount: Int { Int(ts_node_named_child_count(raw)) }

    func child(at index: Int) -> HTTPTSyntaxNode? {
        guard index >= 0, index < childCount else { return nil }
        return HTTPTSyntaxNode(raw: ts_node_child(raw, UInt32(index)), tree: tree)
    }

    func namedChild(at index: Int) -> HTTPTSyntaxNode? {
        guard index >= 0, index < namedChildCount else { return nil }
        return HTTPTSyntaxNode(raw: ts_node_named_child(raw, UInt32(index)), tree: tree)
    }

    var parent: HTTPTSyntaxNode? {
        let raw = ts_node_parent(raw)
        guard !ts_node_is_null(raw) else { return nil }
        return HTTPTSyntaxNode(raw: raw, tree: tree)
    }

    var namedChildren: [HTTPTSyntaxNode] {
        (0..<namedChildCount).compactMap { namedChild(at: $0) }
    }

    func child(byFieldName fieldName: String) -> HTTPTSyntaxNode? {
        let node = fieldName.withCString { cName in
            ts_node_child_by_field_name(raw, cName, UInt32(fieldName.utf8.count))
        }
        guard !ts_node_is_null(node) else { return nil }
        return HTTPTSyntaxNode(raw: node, tree: tree)
    }

    func namedChildren(ofType type: String) -> [HTTPTSyntaxNode] {
        namedChildren.filter { $0.type == type }
    }

    func walk(_ visitor: (HTTPTSyntaxNode) -> Void) {
        visitor(self)
        for index in 0..<childCount {
            child(at: index)?.walk(visitor)
        }
    }
}

enum HTTPRequestParser {
    static func canParseRequest(in text: String, caretUTF16Offset: Int, fileURL: URL?) -> Bool {
        (try? parse(text: text, caretUTF16Offset: caretUTF16Offset, fileURL: fileURL)) != nil
    }

    static func parse(
        text: String,
        caretUTF16Offset: Int,
        fileURL: URL?,
        globals: [String: String] = [:],
        now: Date = Date(),
        random: any HTTPRandomSource = SystemHTTPRandom(),
        historyFolder: URL? = nil
    ) throws -> HTTPPreparedRequest {
        guard let tree = parseTree(text) else {
            throw HTTPRequestParserError.parseFailed
        }
        let spans = requestSpans(in: tree)
        let caretByte = utf16OffsetToByteOffset(text: text, utf16Offset: caretUTF16Offset)
        let end = tree.sourceBytes.count
        guard let span = spans.first(where: { $0.contains(caretByte, sourceEnd: end) }) ?? spans.first else {
            throw HTTPRequestParserError.noRequestAtCaret
        }
        let tail = sourceSlice(tree.sourceBytes, from: span.node.endByte, to: span.boundary)
        let environment = HTTPTemplateEnvironment(
            fileVariables: HTTPSyntax.fileVariables(in: text),
            globals: globals,
            now: now,
            random: random,
            historyFolder: historyFolder ?? HTTPSyntax.historyDirectory()
        )
        let options = HTTPSyntax.optionsByLine(in: text)[span.startLine] ?? HTTPRequestOptions()
        return try buildRequest(
            from: span.node,
            fileURL: fileURL,
            tail: tail,
            environment: environment,
            options: options
        )
    }

    /// Where each request in `text` starts, for the gutter's send buttons. One parse and one pass
    /// over the bytes, so it costs the same however many requests the file has.
    ///
    /// A request line is a method (`PUT`, `GET`, …) or a URL that starts with `http://` or
    /// `https://`. The grammar also reports a request for a trailing body line that has no newline
    /// (the closing `}` of a JSON body). That line is not a request: it stays part of the body.
    static func requestLocations(in text: String) -> [HTTPRequestLocation] {
        guard let tree = parseTree(text) else {
            return []
        }
        return requestSpans(in: tree).map {
            HTTPRequestLocation(startLine: $0.startLine, utf16Range: $0.utf16Range)
        }
    }

    /// One real request. `boundary` is the byte where the next request or `###` separator starts,
    /// so a body the grammar split off (no newline before EOF) still belongs to this request.
    private struct RequestSpan {
        var node: HTTPTSyntaxNode
        var startLine: Int
        var utf16Range: Range<Int>
        var boundary: Int

        func contains(_ caretByte: Int, sourceEnd: Int) -> Bool {
            guard node.startByte <= caretByte else { return false }
            if caretByte < boundary { return true }
            return boundary == sourceEnd && caretByte == sourceEnd
        }
    }

    private static func requestSpans(in tree: HTTPTSyntaxTree) -> [RequestSpan] {
        var requests: [HTTPTSyntaxNode] = []
        var separatorStarts: [Int] = []
        tree.rootNode.walk { node in
            if node.type == "request" {
                requests.append(node)
            } else if node.type == "request_separator" {
                separatorStarts.append(node.startByte)
            }
        }
        let bytes = tree.sourceBytes
        let real = requests
            .filter { HTTPSyntax.isRequestLine(lineText(bytes, at: $0.startByte)) }
            .sorted { $0.startByte < $1.startByte }
        guard !real.isEmpty else { return [] }
        separatorStarts.sort()

        var cursor = 0
        var line = 1
        var utf16Offset = 0
        func advance(to target: Int) {
            let end = min(target, bytes.count)
            while cursor < end {
                let byte = bytes[cursor]
                if byte == 0x0A {
                    line += 1
                }
                if byte & 0xC0 != 0x80 {
                    utf16Offset += byte >= 0xF0 ? 2 : 1
                }
                cursor += 1
            }
        }

        var spans: [RequestSpan] = []
        for (ordinal, node) in real.enumerated() {
            advance(to: node.startByte)
            let start = utf16Offset
            let startLine = line
            advance(to: node.endByte)
            let nextReal = ordinal + 1 < real.count ? real[ordinal + 1].startByte : bytes.count
            let nextSeparator = separatorStarts.first { $0 >= node.endByte } ?? bytes.count
            spans.append(RequestSpan(
                node: node,
                startLine: startLine,
                utf16Range: start..<max(start, utf16Offset),
                boundary: min(nextReal, nextSeparator, bytes.count)
            ))
        }
        return spans
    }

    private static func lineText(_ bytes: [UInt8], at byte: Int) -> String {
        var start = min(max(byte, 0), bytes.count)
        while start > 0, bytes[start - 1] != 0x0A, bytes[start - 1] != 0x0D {
            start -= 1
        }
        var end = min(max(byte, 0), bytes.count)
        while end < bytes.count, bytes[end] != 0x0A, bytes[end] != 0x0D {
            end += 1
        }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private static func sourceSlice(_ bytes: [UInt8], from start: Int, to end: Int) -> String {
        guard start >= 0, end <= bytes.count, start < end else { return "" }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private static func parseTree(_ text: String) -> HTTPTSyntaxTree? {
        let bytes = Array(text.utf8)
        let parser = ts_parser_new()
        defer { ts_parser_delete(parser) }
        ts_parser_set_language(parser, tree_sitter_http())
        guard let tsTree = text.withCString({ cString in
            ts_parser_parse_string(parser, nil, cString, UInt32(bytes.count))
        }) else {
            return nil
        }
        return HTTPTSyntaxTree(tree: tsTree, sourceBytes: bytes)
    }

    private static func utf16OffsetToByteOffset(text: String, utf16Offset: Int) -> Int {
        let clamped = max(0, min(utf16Offset, text.utf16.count))
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: clamped)
        guard let stringIndex = String.Index(utf16Index, within: text) else {
            return text.utf8.count
        }
        return text.utf8.distance(from: text.utf8.startIndex, to: stringIndex)
    }

    private static func buildRequest(
        from node: HTTPTSyntaxNode,
        fileURL: URL?,
        tail: String,
        environment: HTTPTemplateEnvironment,
        options: HTTPRequestOptions
    ) throws -> HTTPPreparedRequest {
        var method = node.child(byFieldName: "method")?.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            ?? "GET"
        let targetText = node.child(byFieldName: "url")?.text ?? ""
        let normalizedTarget = try HTTPSyntax.expand(normalizeTargetURL(targetText), in: environment)
        var headers: [String: String] = [:]
        for (name, value) in parseHeaders(in: node) {
            let expandedName = try HTTPSyntax.expand(name, in: environment)
            headers[expandedName] = try HTTPSyntax.expand(value, in: environment)
        }
        let body = try parseBody(in: node, fileURL: fileURL, tail: tail, environment: environment)
        let digest = HTTPSyntax.applyAuthorization(&headers)
        if method == "GRAPHQL" {
            // `GRAPHQL` is not an HTTP verb: it sends the query as a POST, typed unless the file says otherwise.
            method = "POST"
            if body != nil, !headers.keys.contains(where: { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                headers["Content-Type"] = "application/graphql"
            }
        }
        let lengthKeys = headers.keys.filter { $0.caseInsensitiveCompare("Content-Length") == .orderedSame }
        for key in lengthKeys {
            headers.removeValue(forKey: key)
        }
        if let body {
            headers["Content-Length"] = String(body.count)
        }

        let urlText = HTTPSyntax.encodedURL(normalizedTarget, autoEncode: options.autoEncodeURL)
        guard let url = try resolveURL(target: urlText, headers: headers) else {
            throw HTTPRequestParserError.invalidURL(normalizedTarget)
        }

        let scope = node.text + tail
        let output = try HTTPSyntax.output(in: scope, fileURL: fileURL, environment: environment)
        return HTTPPreparedRequest(
            method: method,
            url: url,
            headers: headers,
            body: body,
            options: options,
            bindings: HTTPSyntax.bindings(in: scope),
            output: output,
            digest: digest
        )
    }

    private static func normalizeTargetURL(_ text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined()
    }

    private static func parseHeaders(in request: HTTPTSyntaxNode) -> [String: String] {
        var headers: [String: String] = [:]
        request.walk { node in
            guard node.type == "header" else { return }
            guard let name = node.child(byFieldName: "name")?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return }
            let value = node.child(byFieldName: "value")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            headers[name] = value
        }
        return headers
    }

    /// `tail` is source the grammar left outside the request node, usually a closing `}` or `]`
    /// on the last line when the file has no newline after it. It belongs to the body.
    /// `>>` and `> {% %}` lines are response directives, not body text.
    private static func parseBody(
        in request: HTTPTSyntaxNode,
        fileURL: URL?,
        tail: String,
        environment: HTTPTemplateEnvironment
    ) throws -> Data? {
        if let bodyNode = request.child(byFieldName: "body") {
            if bodyNode.type == "external_body" {
                return try externalBodyData(from: bodyNode, fileURL: fileURL, environment: environment)
            }
            return try textualBody(
                bodyNode.text,
                tail: tail,
                dropComments: dropsFileComments(bodyNode.type),
                environment: environment
            )
        }
        if let external = findDescendant(ofType: "external_body", in: request) {
            return try externalBodyData(from: external, fileURL: fileURL, environment: environment)
        }
        if let rawBody = findDescendant(ofType: "raw_body", in: request)
            ?? findDescendant(ofType: "json_body", in: request)
            ?? findDescendant(ofType: "xml_body", in: request)
            ?? findDescendant(ofType: "graphql_body", in: request)
            ?? findDescendant(ofType: "multipart_form_data", in: request) {
            return try textualBody(
                rawBody.text,
                tail: tail,
                dropComments: dropsFileComments(rawBody.type),
                environment: environment
            )
        }
        let inline = inlineBodyText(in: request) ?? ""
        return try textualBody(inline, tail: tail, dropComments: true, environment: environment)
    }

    /// A `//` or `#` line above `>>` is a file comment. The grammar still folds it into `raw_body`.
    /// JSON, XML, GraphQL, and multipart bodies keep those lines: a GraphQL `#` comment is payload.
    private static func dropsFileComments(_ bodyType: String) -> Bool {
        bodyType == "raw_body"
    }

    private static func textualBody(
        _ text: String,
        tail: String,
        dropComments: Bool,
        environment: HTTPTemplateEnvironment
    ) throws -> Data? {
        let cleaned = HTTPSyntax.cleaningBody(text + tail, dropComments: dropComments)
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = try HTTPSyntax.expand(trimmed, in: environment)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expanded.isEmpty else { return nil }
        return Data(expanded.utf8)
    }

    private static func inlineBodyText(in request: HTTPTSyntaxNode) -> String? {
        let text = request.text
        guard let separatorRange = text.range(of: "\n\n") ?? text.range(of: "\r\n\r\n") else {
            return nil
        }
        return String(text[separatorRange.upperBound...])
    }

    private static func externalBodyData(
        from node: HTTPTSyntaxNode,
        fileURL: URL?,
        environment: HTTPTemplateEnvironment
    ) throws -> Data {
        let pathText = node.child(byFieldName: "path")?.text
            ?? node.text.replacingOccurrences(of: "<", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = try HTTPSyntax.expand(pathText, in: environment)
        return try loadExternalBody(expanded, fileURL: fileURL)
    }

    private static func findDescendant(ofType type: String, in node: HTTPTSyntaxNode) -> HTTPTSyntaxNode? {
        var match: HTTPTSyntaxNode?
        node.walk { child in
            if match == nil, child.type == type {
                match = child
            }
        }
        return match
    }

    private static func loadExternalBody(_ pathText: String, fileURL: URL?) throws -> Data {
        let trimmed = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (trimmed as NSString).expandingTildeInPath
        let bodyURL: URL
        if (path as NSString).isAbsolutePath {
            bodyURL = URL(fileURLWithPath: path)
        } else if let fileURL {
            bodyURL = URL(fileURLWithPath: path, relativeTo: fileURL.deletingLastPathComponent()).standardizedFileURL
        } else {
            bodyURL = URL(fileURLWithPath: path)
        }
        guard FileManager.default.fileExists(atPath: bodyURL.path) else {
            throw HTTPRequestParserError.externalBodyNotFound(bodyURL.path)
        }
        return try Data(contentsOf: bodyURL)
    }

    private static func resolveURL(target: String, headers: [String: String]) throws -> URL? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }

        if trimmed.hasPrefix("/") {
            guard let hostValue = headers.first(where: { $0.key.caseInsensitiveCompare("Host") == .orderedSame })?.value else {
                throw HTTPRequestParserError.missingHostHeader
            }
            let authority = hostValue.hasPrefix("http://") || hostValue.hasPrefix("https://")
                ? hostValue
                : "http://\(hostValue)"
            return URL(string: authority + trimmed)
        }

        if trimmed.contains("://") {
            return URL(string: trimmed)
        }

        return URL(string: "http://\(trimmed)")
    }
}

/// A request's place in an `.http` file.
struct HTTPRequestLocation: Equatable, Sendable {
    /// 1-based line of the request's first token (its method).
    let startLine: Int
    /// UTF-16 offsets of the request, so an offset inside it selects the request when sending.
    let utf16Range: Range<Int>
}
