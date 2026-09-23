import Foundation
import TreeSitter
import TreeSitterHTTP

/// Minimal tree-sitter wrapper for HTTP request parsing, kept self-contained in `HTTPClient`.
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

public enum HTTPRequestParser {
    public static func canParseRequest(in text: String, caretUTF16Offset: Int, fileURL: URL?) -> Bool {
        (try? parse(text: text, caretUTF16Offset: caretUTF16Offset, fileURL: fileURL)) != nil
    }

    public static func parse(text: String, caretUTF16Offset: Int, fileURL: URL?) throws -> HTTPPreparedRequest {
        guard let tree = parseTree(text) else {
            throw HTTPRequestParserError.parseFailed
        }
        let caretByte = utf16OffsetToByteOffset(text: text, utf16Offset: caretUTF16Offset)
        let requests = collectRequests(from: tree.rootNode)
        guard let request = requests.first(where: { $0.startByte <= caretByte && caretByte <= $0.endByte })
            ?? requests.first else {
            throw HTTPRequestParserError.noRequestAtCaret
        }
        return try buildRequest(from: request, fileURL: fileURL)
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

    private static func collectRequests(from root: HTTPTSyntaxNode) -> [HTTPTSyntaxNode] {
        var requests: [HTTPTSyntaxNode] = []
        root.walk { node in
            if node.type == "request" {
                requests.append(node)
            }
        }
        return requests
    }

    private static func buildRequest(from node: HTTPTSyntaxNode, fileURL: URL?) throws -> HTTPPreparedRequest {
        if node.text.contains("{{") {
            throw HTTPRequestParserError.unsupportedVariable
        }

        let method = node.child(byFieldName: "method")?.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            ?? "GET"
        let targetText = node.child(byFieldName: "url")?.text ?? ""
        let normalizedTarget = normalizeTargetURL(targetText)
        var headers = parseHeaders(in: node)
        let body = try parseBody(in: node, fileURL: fileURL)

        guard let url = try resolveURL(target: normalizedTarget, headers: headers) else {
            throw HTTPRequestParserError.invalidURL(normalizedTarget)
        }

        if body != nil, headers["Content-Length"] == nil, headers["content-length"] == nil {
            headers["Content-Length"] = String(body?.count ?? 0)
        }

        return HTTPPreparedRequest(method: method, url: url, headers: headers, body: body)
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

    private static func parseBody(in request: HTTPTSyntaxNode, fileURL: URL?) throws -> Data? {
        if let bodyNode = request.child(byFieldName: "body") {
            return try bodyData(from: bodyNode, fileURL: fileURL)
        }
        if let external = findDescendant(ofType: "external_body", in: request) {
            return try externalBodyData(from: external, fileURL: fileURL)
        }
        if let rawBody = findDescendant(ofType: "raw_body", in: request)
            ?? findDescendant(ofType: "json_body", in: request)
            ?? findDescendant(ofType: "xml_body", in: request) {
            return textBodyData(from: rawBody)
        }
        return inlineBodyData(in: request)
    }

    private static func inlineBodyData(in request: HTTPTSyntaxNode) -> Data? {
        let text = request.text
        guard let separatorRange = text.range(of: "\n\n") ?? text.range(of: "\r\n\r\n") else {
            return nil
        }
        let body = text[separatorRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : Data(body.utf8)
    }

    private static func bodyData(from node: HTTPTSyntaxNode, fileURL: URL?) throws -> Data? {
        switch node.type {
        case "external_body":
            return try externalBodyData(from: node, fileURL: fileURL)
        case "json_body", "xml_body", "raw_body", "multipart_form_data", "graphql_body":
            return textBodyData(from: node)
        default:
            for child in node.namedChildren {
                if let data = try bodyData(from: child, fileURL: fileURL) {
                    return data
                }
            }
            return textBodyData(from: node)
        }
    }

    private static func textBodyData(from node: HTTPTSyntaxNode) -> Data? {
        let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : Data(text.utf8)
    }

    private static func externalBodyData(from node: HTTPTSyntaxNode, fileURL: URL?) throws -> Data {
        let pathText = node.child(byFieldName: "path")?.text
            ?? node.text.replacingOccurrences(of: "<", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return try loadExternalBody(pathText, fileURL: fileURL)
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
