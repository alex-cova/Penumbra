import CryptoKit
import Foundation

/// How one request is sent. Defaults match IntelliJ's HTTP Client until a `# @no-*` flag says otherwise.
struct HTTPRequestOptions: Equatable, Sendable {
    var followRedirects: Bool
    var useCookieJar: Bool
    var autoEncodeURL: Bool

    init(followRedirects: Bool = true, useCookieJar: Bool = true, autoEncodeURL: Bool = true) {
        self.followRedirects = followRedirects
        self.useCookieJar = useCookieJar
        self.autoEncodeURL = autoEncodeURL
    }
}

/// `> {% client.global.set("name", response.body.token); %}`. `jsonPath` nil keeps the raw body.
struct HTTPResponseBinding: Equatable, Sendable {
    var name: String
    var jsonPath: String?
}

/// A `>>` or `>>!` path that has already been expanded and confined to an allowed folder.
struct HTTPResponseOutput: Equatable, Sendable {
    var url: URL
    var overwrite: Bool
}

struct HTTPDigestLogin: Equatable, Sendable {
    var username: String
    var password: String
}

/// In-memory `client.global` values for one window. File `@` variables stay in the `.http` file.
final class HTTPGlobalStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func set(_ name: String, _ value: String) {
        lock.lock()
        values[name] = value
        lock.unlock()
    }
}

/// Cookie jar handed to `URLSession`. A private storage is not the process-wide shared jar.
struct HTTPCookieJar: @unchecked Sendable {
    let storage: HTTPCookieStorage

    init() {
        let storage = HTTPCookieStorage()
        storage.cookieAcceptPolicy = .always
        self.storage = storage
    }
}

protocol HTTPRandomSource: Sendable {
    func uuid() -> String
    func integer(from lower: Int, to upper: Int) -> Int
    func float(from lower: Double, to upper: Double) -> Double
    func alphabetic(count: Int) -> String
    func alphanumeric(count: Int) -> String
    func hexadecimal(count: Int) -> String
}

struct SystemHTTPRandom: HTTPRandomSource {
    func uuid() -> String { UUID().uuidString.lowercased() }

    func integer(from lower: Int, to upper: Int) -> Int {
        Int.random(in: min(lower, upper)...max(lower, upper))
    }

    func float(from lower: Double, to upper: Double) -> Double {
        let low = min(lower, upper)
        let high = max(lower, upper)
        return Double.random(in: low...high)
    }

    func alphabetic(count: Int) -> String {
        Self.pick(count, from: Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    }

    func alphanumeric(count: Int) -> String {
        Self.pick(count, from: Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
    }

    func hexadecimal(count: Int) -> String {
        Self.pick(count, from: Array("0123456789abcdef"))
    }

    private static func pick(_ count: Int, from alphabet: [Character]) -> String {
        guard count > 0 else { return "" }
        return String((0..<count).map { _ in alphabet.randomElement()! })
    }
}

struct HTTPTemplateEnvironment: Sendable {
    var fileVariables: [String: String]
    var globals: [String: String]
    var now: Date
    var random: any HTTPRandomSource
    var historyFolder: URL
}

enum HTTPSyntax {
    static let requestMethods: Set<String> = [
        "OPTIONS", "GET", "HEAD", "POST", "PUT", "DELETE",
        "TRACE", "CONNECT", "PATCH", "LIST", "GRAPHQL", "WEBSOCKET",
    ]

    static let maximumGeneratedLength = 4_096
    private static let maximumExpansionDepth = 8

    /// `PUT https://…` or a bare `https://…`. A body line such as `}` is not a request.
    static func isRequestLine(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let lowered = trimmed.prefix(8).lowercased()
        if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") {
            return true
        }
        guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return false
        }
        return requestMethods.contains(String(trimmed[..<space]))
    }

    /// `@name = value` anywhere in the file. A later line wins. Quotes stay part of the value.
    static func fileVariables(in text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in lines(of: text) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard trimmed.first == "@", let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[trimmed.index(after: trimmed.startIndex)..<equals]
                .trimmingCharacters(in: .whitespaces)
            guard isVariableName(name) else { continue }
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            values[String(name)] = String(value)
        }
        return values
    }

    /// `# @no-redirect` (and `//`) applies to the next request line, not to the comment itself.
    static func optionsByLine(in text: String) -> [Int: HTTPRequestOptions] {
        var pending = HTTPRequestOptions()
        var armed = false
        var result: [Int: HTTPRequestOptions] = [:]
        for (index, line) in lines(of: text).enumerated() {
            if let flag = requestFlag(on: line) {
                switch flag {
                case "no-redirect": pending.followRedirects = false
                case "no-cookie-jar": pending.useCookieJar = false
                case "no-auto-encoding": pending.autoEncodeURL = false
                default: break
                }
                armed = true
                continue
            }
            if isRequestLine(line) {
                if armed {
                    result[index + 1] = pending
                }
                pending = HTTPRequestOptions()
                armed = false
            }
        }
        return result
    }

    static func historyDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("HTTPHistory", isDirectory: true)
    }

    static func isoTimestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// Substitute `{{name}}` and `{{$…}}`. Dynamic names are evaluated once per occurrence.
    static func expand(_ text: String, in environment: HTTPTemplateEnvironment) throws -> String {
        try expand(text, in: environment, depth: 0, stack: [])
    }

    static func bindings(in scope: String) -> [HTTPResponseBinding] {
        let ns = scope as NSString
        return bindingExpression.matches(in: scope, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let name = ns.substring(with: match.range(at: 1))
            guard !name.isEmpty else { return nil }
            let pathRange = match.range(at: 2)
            let path = pathRange.location == NSNotFound ? nil : ns.substring(with: pathRange)
            return HTTPResponseBinding(name: name, jsonPath: path)
        }
    }

    /// The last `>>` or `>>!` in this request. The path must stay in the file's folder or the history folder.
    static func output(
        in scope: String,
        fileURL: URL?,
        environment: HTTPTemplateEnvironment
    ) throws -> HTTPResponseOutput? {
        var found: (overwrite: Bool, path: String)?
        for line in lines(of: scope) {
            if let line = outputLine(line) {
                found = line
            }
        }
        guard let found else { return nil }
        let expanded = try expand(found.path, in: environment)
        let url = try resolveOutputPath(expanded, fileURL: fileURL, historyFolder: environment.historyFolder)
        return HTTPResponseOutput(url: url, overwrite: found.overwrite)
    }

    /// Drop `>>`, `>>!`, and response-handler lines. Comment lines go only when this text is not a real body.
    static func cleaningBody(_ text: String, dropComments: Bool) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let parts = normalized.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let kept = parts.filter { line in
            if outputLine(line) != nil || isResponseScriptLine(line) { return false }
            if dropComments {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") { return false }
            }
            return true
        }
        guard kept.count != parts.count else { return text }
        let joined = kept.joined(separator: "\n")
        return text.contains("\r\n") ? joined.replacingOccurrences(of: "\n", with: "\r\n") : joined
    }

    static func encodedURL(_ text: String, autoEncode: Bool) -> String {
        guard autoEncode else { return text }
        return text.addingPercentEncoding(withAllowedCharacters: urlAllowed) ?? text
    }

    /// `Basic user pass` becomes `Basic base64(user:pass)`. One token is left as-is.
    static func basicAuthorization(in value: String) -> String? {
        let parts = value.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0].caseInsensitiveCompare("Basic") == .orderedSame else { return nil }
        let token = Data("\(parts[1]):\(parts[2])".utf8).base64EncodedString()
        return "Basic \(token)"
    }

    /// `Digest user pass` when the value is still the two plaintext tokens (no `=`).
    static func digestLogin(in value: String) -> HTTPDigestLogin? {
        guard !value.contains("=") else { return nil }
        let parts = value.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0].caseInsensitiveCompare("Digest") == .orderedSame else { return nil }
        return HTTPDigestLogin(username: String(parts[1]), password: String(parts[2]))
    }

    static func applyAuthorization(_ headers: inout [String: String]) -> HTTPDigestLogin? {
        guard let key = headers.keys.first(where: { $0.caseInsensitiveCompare("Authorization") == .orderedSame }) else {
            return nil
        }
        let value = headers[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let login = digestLogin(in: value) {
            headers.removeValue(forKey: key)
            return login
        }
        if let encoded = basicAuthorization(in: value) {
            headers[key] = encoded
        }
        return nil
    }

    static func resolveOutputPath(_ path: String, fileURL: URL?, historyFolder: URL) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HTTPRequestParserError.responsePathNotAllowed(path)
        }
        let candidate: URL
        if (trimmed as NSString).isAbsolutePath {
            candidate = URL(fileURLWithPath: trimmed)
        } else if let directory = fileURL?.deletingLastPathComponent() {
            candidate = directory.appendingPathComponent(trimmed)
        } else {
            throw HTTPRequestParserError.responsePathNotAllowed(path)
        }
        // standardizedFileURL leaves ".." in place when a parent folder does not exist yet.
        // A prefix check would then treat "/history/../secret" as inside "/history".
        let resolved = URL(fileURLWithPath: lexicalPath(candidate.standardizedFileURL.path))
        let roots = [fileURL?.deletingLastPathComponent(), historyFolder].compactMap { $0 }
        guard roots.contains(where: { contains(resolved, in: $0) }) else {
            throw HTTPRequestParserError.responsePathNotAllowed(path)
        }
        return resolved
    }

    static func contains(_ url: URL, in root: URL) -> Bool {
        let path = lexicalPath(url.standardizedFileURL.path)
        var rootPath = lexicalPath(root.standardizedFileURL.path)
        if rootPath.count > 1, rootPath.hasSuffix("/") {
            rootPath.removeLast()
        }
        if rootPath == "/" {
            return path.hasPrefix("/")
        }
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    /// Remove `.` and `..` without touching the file system, so a missing history folder still collapses.
    static func lexicalPath(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if absolute {
                    if !parts.isEmpty { parts.removeLast() }
                } else if let last = parts.last, last != ".." {
                    parts.removeLast()
                } else {
                    parts.append("..")
                }
                continue
            }
            parts.append(String(component))
        }
        if parts.isEmpty { return absolute ? "/" : "." }
        return (absolute ? "/" : "") + parts.joined(separator: "/")
    }

    private static func isVariableName(_ name: some StringProtocol) -> Bool {
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
    }

    private static func requestFlag(on line: String) -> String? {
        var text = line.drop(while: { $0 == " " || $0 == "\t" })
        if text.hasPrefix("//") {
            text = text.dropFirst(2)
        } else if text.hasPrefix("#") {
            text = text.dropFirst()
        } else {
            return nil
        }
        text = text.drop(while: { $0 == " " || $0 == "\t" })
        guard text.first == "@" else { return nil }
        let name = text.dropFirst().trimmingCharacters(in: .whitespaces)
        switch name {
        case "no-redirect", "no-cookie-jar", "no-auto-encoding":
            return name
        default:
            return nil
        }
    }

    private static func outputLine(_ line: String) -> (overwrite: Bool, path: String)? {
        var text = line.drop(while: { $0 == " " || $0 == "\t" })
        guard text.hasPrefix(">>") else { return nil }
        text = text.dropFirst(2)
        let overwrite = text.first == "!"
        if overwrite {
            text = text.dropFirst()
        }
        let path = text.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return (overwrite, String(path))
    }

    static func isResponseScriptLine(_ line: String) -> Bool {
        let text = line.drop(while: { $0 == " " || $0 == "\t" })
        return text.hasPrefix(">{%") || text.hasPrefix("> {%")
    }

    static func isDirectiveLine(_ line: String) -> Bool {
        outputLine(line) != nil || isResponseScriptLine(line)
    }

    private static func lines(of text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
    }

    private static func expand(
        _ text: String,
        in environment: HTTPTemplateEnvironment,
        depth: Int,
        stack: [String]
    ) throws -> String {
        guard text.contains("{{") else { return text }
        let ns = text as NSString
        let matches = placeholderExpression.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        guard depth < maximumExpansionDepth else {
            throw HTTPRequestParserError.cyclicVariable(stack.last ?? "template")
        }
        var result = ""
        var cursor = 0
        for match in matches {
            let full = match.range
            result += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            let expression = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            result += try resolve(expression, in: environment, depth: depth, stack: stack)
            cursor = full.upperBound
        }
        result += ns.substring(from: cursor)
        if result.contains("{{"), result != text {
            return try expand(result, in: environment, depth: depth + 1, stack: stack)
        }
        return result
    }

    private static func resolve(
        _ expression: String,
        in environment: HTTPTemplateEnvironment,
        depth: Int,
        stack: [String]
    ) throws -> String {
        if expression.hasPrefix("$") {
            return try evaluateDynamic(expression, in: environment)
        }
        if stack.contains(expression) {
            throw HTTPRequestParserError.cyclicVariable(expression)
        }
        if let raw = environment.fileVariables[expression] {
            return try expand(raw, in: environment, depth: depth + 1, stack: stack + [expression])
        }
        if let raw = environment.globals[expression] {
            return try expand(raw, in: environment, depth: depth + 1, stack: stack + [expression])
        }
        throw HTTPRequestParserError.unknownVariable(expression)
    }

    private static func evaluateDynamic(_ expression: String, in environment: HTTPTemplateEnvironment) throws -> String {
        let call = parseCall(expression)
        switch call.name {
        case "$uuid", "$random.uuid":
            guard call.arguments == nil || call.arguments?.isEmpty == true else {
                throw HTTPRequestParserError.invalidTemplate(expression)
            }
            return environment.random.uuid()
        case "$timestamp":
            return String(Int(environment.now.timeIntervalSince1970))
        case "$isoTimestamp":
            return isoTimestamp(from: environment.now)
        case "$randomInt":
            return String(environment.random.integer(from: 0, to: 1000))
        case "$random.integer":
            let bounds = try integerBounds(call.arguments, expression: expression, empty: (0, 1000))
            return String(environment.random.integer(from: bounds.0, to: bounds.1))
        case "$random.float":
            let bounds = try floatBounds(call.arguments, expression: expression)
            return String(environment.random.float(from: bounds.0, to: bounds.1))
        case "$random.alphabetic":
            return environment.random.alphabetic(count: try length(call.arguments, expression: expression, empty: 10))
        case "$random.alphanumeric":
            return environment.random.alphanumeric(count: try length(call.arguments, expression: expression, empty: 10))
        case "$random.hexadecimal":
            return environment.random.hexadecimal(count: try length(call.arguments, expression: expression, empty: 10))
        case "$random.email":
            guard call.arguments == nil || call.arguments?.isEmpty == true else {
                throw HTTPRequestParserError.invalidTemplate(expression)
            }
            return environment.random.alphanumeric(count: 8) + "@example.com"
        case "$historyFolder":
            return environment.historyFolder.path
        default:
            throw HTTPRequestParserError.unknownVariable(expression)
        }
    }

    private struct Call {
        var name: String
        var arguments: [String]?
    }

    private static func parseCall(_ expression: String) -> Call {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let open = trimmed.firstIndex(of: "("), open > trimmed.startIndex else {
            return Call(name: trimmed, arguments: nil)
        }
        let name = trimmed[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        let inside = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        if inside.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Call(name: String(name), arguments: [])
        }
        let arguments = inside.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Call(name: String(name), arguments: arguments)
    }

    private static func integerBounds(
        _ arguments: [String]?,
        expression: String,
        empty: (Int, Int)
    ) throws -> (Int, Int) {
        guard let arguments else { return empty }
        if arguments.isEmpty { return empty }
        guard arguments.count == 2, let from = Int(arguments[0]), let to = Int(arguments[1]) else {
            throw HTTPRequestParserError.invalidTemplate(expression)
        }
        return (min(from, to), max(from, to))
    }

    private static func floatBounds(_ arguments: [String]?, expression: String) throws -> (Double, Double) {
        guard let arguments else { return (0, 1) }
        if arguments.isEmpty { return (0, 1) }
        guard arguments.count == 2, let from = Double(arguments[0]), let to = Double(arguments[1]) else {
            throw HTTPRequestParserError.invalidTemplate(expression)
        }
        return (min(from, to), max(from, to))
    }

    private static func length(_ arguments: [String]?, expression: String, empty: Int) throws -> Int {
        let count: Int
        if arguments == nil || arguments?.isEmpty == true {
            count = empty
        } else if arguments?.count == 1, let value = Int(arguments?[0] ?? "") {
            count = value
        } else {
            throw HTTPRequestParserError.invalidTemplate(expression)
        }
        guard count >= 0, count <= maximumGeneratedLength else {
            throw HTTPRequestParserError.invalidTemplate(expression)
        }
        return count
    }

    private static let urlAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~:/?#[]@!$&'()*+,;=%")
        return set
    }()

    private static let placeholderExpression: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"\{\{[ \t]*([^{}\r\n]+?)[ \t]*\}\}"#)
        } catch {
            preconditionFailure("Invalid HTTP placeholder pattern")
        }
    }()

    private static let bindingExpression: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"client\.global\.set\(\s*"([^"]+)"\s*,\s*response\.body(?:\.([A-Za-z0-9_.]+))?\s*\)"#
            )
        } catch {
            preconditionFailure("Invalid HTTP response-handler pattern")
        }
    }()
}

enum HTTPResponseValues {
    /// `nil` path is the raw body. A dot path reads JSON. Booleans stay `true` / `false`.
    static func string(in data: Data, path: String?) -> String? {
        if path == nil || path?.isEmpty == true {
            return String(data: data, encoding: .utf8)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        var current: Any = json
        for part in path!.split(separator: ".") where !part.isEmpty {
            guard let object = current as? [String: Any], let next = object[String(part)] else {
                return nil
            }
            current = next
        }
        return stringify(current)
    }

    private static func stringify(_ value: Any) -> String? {
        if value is NSNull { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}

enum HTTPResponseCapture {
    struct Outcome: Equatable, Sendable {
        var notes: [String]
        var errors: [String]
    }

    /// Stores each bound value and reports the name only, never the value.
    static func apply(bindings: [HTTPResponseBinding], data: Data, store: HTTPGlobalStore) -> Outcome {
        var notes: [String] = []
        var errors: [String] = []
        for binding in bindings {
            if let value = HTTPResponseValues.string(in: data, path: binding.jsonPath) {
                store.set(binding.name, value)
                notes.append("Saved \(binding.name)")
            } else {
                errors.append("Response has no value at \(binding.jsonPath ?? "body").")
            }
        }
        return Outcome(notes: notes, errors: errors)
    }
}

enum HTTPResponseFiles {
    /// `>>` adds `-N` before the extension when the file exists. `>>!` uses the path as given.
    static func destination(for output: HTTPResponseOutput, fileManager: FileManager = .default) -> URL {
        let url = output.url
        if output.overwrite || !fileManager.fileExists(atPath: url.path) {
            return url
        }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let directory = url.deletingLastPathComponent()
        var index = 1
        while index < 10_000 {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
        return url
    }

    @discardableResult
    static func write(_ data: Data, to output: HTTPResponseOutput, fileManager: FileManager = .default) throws -> URL {
        let url = destination(for: output, fileManager: fileManager)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }
}

enum HTTPDigest {
    struct Challenge: Equatable, Sendable {
        var realm: String
        var nonce: String
        var opaque: String?
        var qop: [String]
        var algorithm: String?
    }

    static func parse(_ header: String) -> Challenge? {
        let fields = parameters(in: header)
        guard let realm = fields["realm"], let nonce = fields["nonce"] else { return nil }
        let qop = fields["qop"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? []
        return Challenge(realm: realm, nonce: nonce, opaque: fields["opaque"], qop: qop, algorithm: fields["algorithm"])
    }

    /// Path plus query, which is the digest-uri.
    static func uri(for url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        guard let query = url.query, !query.isEmpty else { return path }
        return path + "?" + query
    }

    static func authorization(
        username: String,
        password: String,
        method: String,
        uri: String,
        challenge: Challenge,
        nc: String,
        cnonce: String
    ) -> String? {
        let algorithm = (challenge.algorithm ?? "MD5").lowercased()
        guard algorithm == "md5" else { return nil }
        let qop = challenge.qop.isEmpty ? nil : (challenge.qop.contains("auth") ? "auth" : nil)
        if !challenge.qop.isEmpty, qop == nil { return nil }

        let ha1 = md5Hex("\(username):\(challenge.realm):\(password)")
        let ha2 = md5Hex("\(method):\(uri)")
        let response: String
        if let qop {
            response = md5Hex("\(ha1):\(challenge.nonce):\(nc):\(cnonce):\(qop):\(ha2)")
        } else {
            response = md5Hex("\(ha1):\(challenge.nonce):\(ha2)")
        }

        var parts = [
            "username=\(quote(username))",
            "realm=\(quote(challenge.realm))",
            "nonce=\(quote(challenge.nonce))",
            "uri=\(quote(uri))",
            "algorithm=MD5",
        ]
        if let qop {
            parts.append("qop=\(qop)")
            parts.append("nc=\(nc)")
            parts.append("cnonce=\(quote(cnonce))")
        }
        parts.append("response=\(quote(response))")
        if let opaque = challenge.opaque {
            parts.append("opaque=\(quote(opaque))")
        }
        return "Digest " + parts.joined(separator: ", ")
    }

    static func randomCnonce() -> String {
        SystemHTTPRandom().hexadecimal(count: 16)
    }

    static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func parameters(in header: String) -> [String: String] {
        var text = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("digest") {
            text = String(text.dropFirst("digest".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var result: [String: String] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index] == "," || text[index] == " " || text[index] == "\t" {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            let keyStart = index
            while index < text.endIndex, text[index] != "=", text[index] != ",", text[index] != " " {
                index = text.index(after: index)
            }
            let key = text[keyStart..<index].lowercased()
            guard index < text.endIndex, text[index] == "=" else { break }
            index = text.index(after: index)
            let value: String
            if index < text.endIndex, text[index] == "\"" {
                index = text.index(after: index)
                var decoded = ""
                while index < text.endIndex {
                    if text[index] == "\\", text.index(after: index) < text.endIndex {
                        let next = text.index(after: index)
                        decoded.append(text[next])
                        index = text.index(after: next)
                        continue
                    }
                    if text[index] == "\"" {
                        index = text.index(after: index)
                        break
                    }
                    decoded.append(text[index])
                    index = text.index(after: index)
                }
                value = decoded
            } else {
                let valueStart = index
                while index < text.endIndex, text[index] != "," {
                    index = text.index(after: index)
                }
                value = text[valueStart..<index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }
}
