import Foundation

/// A `.http` request built from an endpoint's mapping: method, route with path variables, required parameters and headers, the
/// content types the mapping names and a JSON body skeleton when the body type is declared in the project. Nothing is sent: the
/// text opens in an editor buffer and the user runs it.
public enum SpringHTTPRequest {
    /// Where requests go. `value` is nil when no configuration names a port, which the request then says explicitly.
    public struct BaseURL: Equatable, Sendable {
        public let value: String?
        /// Where the value came from (`server.port in application.yml`), or why there is none.
        public let note: String
        public static let unknown = BaseURL(value: nil, note: "server.port is not set in the project's configuration, so the port cannot be known statically.")
    }

    /// The base URL the configuration names: `server.port` (a `${…:default}` placeholder uses its default), `server.ssl.enabled`
    /// for the scheme, and `server.servlet.context-path` (MVC) or `spring.webflux.base-path` (WebFlux). Without a port the
    /// result is ``BaseURL/unknown``: the framework default is not assumed, because the app may run elsewhere.
    public static func baseURL(config: SpringConfigModel?, stack: SpringWebStack) -> BaseURL {
        guard let config, let portValue = config.effective(key: "server.port")?.winner.entry.value else { return .unknown }
        var port = portValue.trimmingCharacters(in: .whitespaces)
        if port.hasPrefix("${"), port.hasSuffix("}") {
            let inner = port.dropFirst(2).dropLast()
            guard let colon = inner.firstIndex(of: ":") else { return .unknown }
            port = String(inner[inner.index(after: colon)...])
        }
        guard Int(port) != nil, port != "0" else { return .unknown }
        let ssl = config.effective(key: "server.ssl.enabled")?.winner.entry.value?.lowercased() == "true"
        let pathKey = stack == .webflux ? "spring.webflux.base-path" : "server.servlet.context-path"
        var context = config.effective(key: pathKey)?.winner.entry.value?.trimmingCharacters(in: .whitespaces) ?? ""
        if context == "/" { context = "" }
        if !context.isEmpty, !context.hasPrefix("/") { context = "/" + context }
        let file = config.effective(key: "server.port")?.winner.file.url.lastPathComponent ?? "configuration"
        return BaseURL(value: "\(ssl ? "https" : "http")://localhost:\(port)\(context)", note: "from server.port in \(file)")
    }

    public static func suggestedName(for endpoint: SpringEndpoint) -> String {
        let method = endpoint.conditions.methods.first ?? "ANY"
        let route = endpoint.route.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let slug = String(route).split(separator: "-").joined(separator: "-")
        return "\(method.lowercased())-\(slug.isEmpty ? "root" : slug).http"
    }

    /// The request text. Variables (`{{id}}`) are defined at the top with sample values, labelled as such.
    public static func render(_ endpoint: SpringEndpoint, base: BaseURL, config: SpringConfigModel? = nil) -> String {
        let resolved = config.map { endpoint.resolvedRoute(using: $0) } ?? (route: endpoint.route, unresolved: endpoint.placeholderKeys)
        let routeText = resolved.route
        var variables: [(name: String, value: String, comment: String)] = []
        func variable(_ raw: String, type: String, comment: String) -> String {
            let name = raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" ? Character($0) : "_" }
            let clean = String(name)
            if !variables.contains(where: { $0.name == clean }) { variables.append((clean, sample(for: type), comment)) }
            return "{{\(clean)}}"
        }

        // Path: each `{name}` becomes `{{name}}`; wildcards stay as written because there is nothing to name.
        var path = ""
        var cursor = 0
        let units = Array(routeText.utf16)
        for v in SpringRoute.variables(in: routeText) {
            path += String(utf16CodeUnits: Array(units[cursor..<v.range.lowerBound]), count: v.range.lowerBound - cursor)
            let parameter = endpoint.parameters.first { $0.kind == .pathVariable && $0.bindingName == v.name }
            path += variable(v.name, type: parameter?.type ?? "String", comment: "\(v.name): \(parameter?.type ?? "String") (path variable)")
            cursor = v.range.upperBound
        }
        path += String(utf16CodeUnits: Array(units[cursor...]), count: units.count - cursor)

        var query: [String] = []
        var optional: [String] = []
        for p in endpoint.parameters where p.kind == .requestParam {
            if p.isRequired && !p.isImplicit { query.append("\(p.bindingName)=\(variable(p.bindingName, type: p.type, comment: "\(p.bindingName): \(p.type) (request parameter)"))") }
            else { optional.append(p.bindingName) }
        }
        for condition in endpoint.conditions.params where !condition.hasPrefix("!") && !condition.contains("!=") {
            if let eq = condition.firstIndex(of: "=") { query.append("\(condition[..<eq])=\(condition[condition.index(after: eq)...])") }
            else { query.append("\(condition)=\(variable(condition, type: "String", comment: "\(condition) (required by the mapping's params condition)"))") }
        }

        var headers: [(String, String)] = []
        if let accept = endpoint.conditions.produces.first(where: { !$0.hasPrefix("!") }) { headers.append(("Accept", accept)) }
        let hasBody = endpoint.requestBodyType != nil
        let isMultipart = endpoint.parameters.contains { $0.kind == .requestPart } || endpoint.conditions.consumes.contains { $0.hasPrefix("multipart/") }
        if let consumes = endpoint.conditions.consumes.first(where: { !$0.hasPrefix("!") && !$0.hasPrefix("multipart/") }) {
            headers.append(("Content-Type", consumes))
        } else if hasBody, !isMultipart {
            headers.append(("Content-Type", "application/json"))
        }
        for p in endpoint.parameters where p.kind == .requestHeader && p.isRequired && !p.bindsAll {
            headers.append((p.bindingName, variable(p.bindingName, type: p.type, comment: "\(p.bindingName): \(p.type) (request header)")))
        }
        for condition in endpoint.conditions.headers where !condition.hasPrefix("!") && !condition.contains("!=") {
            if let eq = condition.firstIndex(of: "=") { headers.append((String(condition[..<eq]), String(condition[condition.index(after: eq)...]))) }
            else { headers.append((condition, variable(condition, type: "String", comment: "\(condition) (required by the mapping's headers condition)"))) }
        }

        let method: String
        var notes: [String] = []
        if let first = endpoint.conditions.methods.first { method = first }
        else {
            method = hasBody ? "POST" : "GET"
            notes.append("# The mapping accepts any HTTP method; \(method) is used here.")
        }

        var out = "### \(endpoint.title) — \(endpoint.handlerTitle)\n"
        out += "# Generated from the Spring mapping. Not sent until you run it.\n"
        if let value = base.value {
            out += "# Base URL \(base.note); change it if the application runs elsewhere.\n@baseUrl = \(value)\n"
        } else {
            out += "# \(base.note)\n@baseUrl = http://localhost:<set-the-port>\n"
        }
        if !variables.isEmpty {
            out += "# Sample values: replace them before sending.\n"
            for v in variables { out += "# \(v.comment)\n@\(v.name) = \(v.value)\n" }
        }
        if !resolved.unresolved.isEmpty { notes.append("# Not resolvable statically, left as written: \(resolved.unresolved.map { "${\($0)}" }.joined(separator: ", "))") }
        for n in notes { out += n + "\n" }
        if !optional.isEmpty { out += "# Optional request parameters: \(optional.joined(separator: ", "))\n" }
        if endpoint.requestBodyType != nil, endpoint.requestBodySkeleton == nil, !isMultipart {
            out += "# Request body: \(endpoint.requestBodyType!) (its fields are not declared in the project's sources).\n"
        }
        if isMultipart { out += "# Multipart request: add the parts (\(endpoint.parameters.filter { $0.kind == .requestPart }.map(\.bindingName).joined(separator: ", "))) in the body.\n" }
        out += "\n\(method) {{baseUrl}}\(path == "/" ? "" : path)\(query.isEmpty ? "" : "?" + query.joined(separator: "&"))\n"
        for (name, value) in headers { out += "\(name): \(value)\n" }
        if hasBody, !isMultipart, let skeleton = endpoint.requestBodySkeleton {
            out += "\n\(skeleton)\n"
        }
        return out
    }

    private static func sample(for type: String) -> String {
        let simple = type.split(separator: "<").first.map(String.init)?.split(separator: ".").last.map(String.init) ?? type
        switch simple {
        case "Long", "long", "Integer", "int", "Short", "short", "Byte", "byte", "BigInteger": return "1"
        case "Double", "double", "Float", "float", "BigDecimal": return "1.0"
        case "Boolean", "boolean": return "true"
        case "UUID": return "00000000-0000-0000-0000-000000000000"
        case "LocalDate": return "2000-01-01"
        case "LocalDateTime": return "2000-01-01T00:00:00"
        default: return "value"
        }
    }
}

extension SpringEndpoint {
    /// The route with `${key}` / `${key:default}` replaced by the value the configuration files give under the analysis profiles,
    /// else the default. Keys with neither stay as written and are listed in `unresolved`; environment variables and command-line
    /// arguments rank above every file and are invisible here, so a resolved value is the file's, not a guarantee.
    public func resolvedRoute(using config: SpringConfigModel) -> (route: String, unresolved: [String]) {
        guard route.contains("${"), let regex = try? NSRegularExpression(pattern: #"\$\{([^}:]+)(?::([^}]*))?\}"#) else { return (route, []) }
        let ns = route as NSString
        var out = "", cursor = 0
        var unresolved: [String] = []
        for m in regex.matches(in: route, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let key = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if let value = config.effective(key: key)?.winner.entry.value { out += value }
            else if m.range(at: 2).location != NSNotFound { out += ns.substring(with: m.range(at: 2)) }
            else { out += ns.substring(with: m.range); unresolved.append(key) }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return (SpringRoute.prependSlash(out), unresolved)
    }
}
