import Foundation
import JavaIntelligence

/// Which web stack handles an endpoint. Spring Boot picks MVC when both are on the classpath, so the module's dependencies
/// decide; a project without build information falls back to what the handler's own types say.
public enum SpringWebStack: String, Hashable, Sendable {
    case mvc, webflux, unknown
    public var title: String {
        switch self {
        case .mvc: "Spring MVC"
        case .webflux: "Spring WebFlux"
        case .unknown: "Spring web"
        }
    }
}

public struct SpringEndpointID: Hashable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(raw: String) { self.raw = raw }
    public var description: String { raw }
}

/// What a `RequestMappingInfo` matches besides the path. Sorted, so equality is Spring's own set equality.
public struct SpringRequestConditions: Hashable, Sendable {
    /// Upper-case HTTP methods; empty means "any method".
    public var methods: [String] = []
    public var params: [String] = []
    public var headers: [String] = []
    public var consumes: [String] = []
    public var produces: [String] = []

    public init() {}

    public var isUnrestricted: Bool { methods.isEmpty && params.isEmpty && headers.isEmpty && consumes.isEmpty && produces.isEmpty }

    static let methodOrder = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "TRACE"]
    static func sortMethods(_ methods: [String]) -> [String] {
        Array(Set(methods)).sorted {
            (methodOrder.firstIndex(of: $0) ?? 99, $0) < (methodOrder.firstIndex(of: $1) ?? 99, $1)
        }
    }
}

/// How sure the index is that the route and conditions are what Spring will register.
public enum SpringEndpointConfidence: Hashable, Sendable {
    /// Every mapping value was a string literal or a recognised constant.
    case exact
    /// Some value is an expression the static analysis cannot evaluate (a constant in another class, a method call),
    /// so the route shows it in angle brackets and nothing is claimed about duplicates or conflicts.
    case partial(reasons: [String])

    public var isExact: Bool { if case .exact = self { return true } else { return false } }
}

public struct SpringEndpointParameter: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case pathVariable, requestParam, requestHeader, requestBody, requestPart, cookie, modelAttribute, matrixVariable
        case requestAttribute, sessionAttribute

        public var title: String {
            switch self {
            case .pathVariable: "Path variable"
            case .requestParam: "Request parameter"
            case .requestHeader: "Request header"
            case .requestBody: "Request body"
            case .requestPart: "Multipart part"
            case .cookie: "Cookie"
            case .modelAttribute: "Model attribute"
            case .matrixVariable: "Matrix variable"
            case .requestAttribute: "Request attribute"
            case .sessionAttribute: "Session attribute"
            }
        }
    }

    /// The Java parameter name.
    public let name: String
    /// The name the request uses: the annotation's `value`/`name`, else the Java name.
    public let bindingName: String
    public let kind: Kind
    public let type: String
    public let isRequired: Bool
    public let defaultValue: String?
    /// True when no binding annotation was written and Spring infers one from the type (a simple type is a query parameter).
    public let isImplicit: Bool
    /// `Map<String, String>` bindings take every variable/parameter, so a name is not checked against them.
    public let bindsAll: Bool
    public let validations: [String]
    /// The whole parameter, for navigation and diagnostics.
    public let location: SpringSourceLocation
    public let nameRange: Range<Int>
    /// The binding annotation, when written (the range a quick fix rewrites).
    public let annotationRange: Range<Int>?
}

/// What a handler returns, with the payload separated from the wrappers that carry it.
public struct SpringEndpointResponse: Hashable, Sendable {
    /// The declared type as written: `Mono<ResponseEntity<Customer>>`.
    public let declared: String
    /// The type of the body, wrappers removed: `Customer`. `nil` for `void` and for a view name.
    public let payload: String?
    /// Wrappers removed, outermost first: `["Mono", "ResponseEntity"]`.
    public let wrappers: [String]
    /// A `Flux`/`Publisher`/`Stream` of payloads rather than one payload (the body is a sequence).
    public let isStream: Bool
    /// The return value is written to the body (`@ResponseBody`, `@RestController`, `ResponseEntity`), not resolved as a view name.
    public let isBody: Bool
    public let status: String?
}

/// An `@ExceptionHandler` method that may answer for an endpoint's exceptions.
public struct SpringExceptionHandlerRef: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        case controller
        case advice(String)
        /// An advice whose selector (`annotations = …`) cannot be evaluated statically.
        case adviceMaybe(String)
    }
    public let method: String
    public let owner: String
    public let exceptions: [String]
    public let scope: Scope
    public let location: SpringSourceLocation
}

public struct SpringEndpoint: Identifiable, Hashable, Sendable {
    public static func == (l: SpringEndpoint, r: SpringEndpoint) -> Bool {
        l.id == r.id && l.route == r.route && l.conditions == r.conditions && l.handlerLocation == r.handlerLocation
            && l.certainty == r.certainty && l.stack == r.stack
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(route) }

    public var id: SpringEndpointID
    public var contextID: String
    public var module: String?
    public var stack: SpringWebStack
    /// Qualified name of the controller class the endpoint belongs to (the bean's class, not the declaring interface).
    public let controller: String
    public let handler: String
    /// `find(java.lang.Long)`: the handler's identity within its class.
    public let handlerSignature: String
    /// The full route, class and method paths combined as Spring does, with a leading slash. `/` for the root mapping.
    /// `${…}` placeholders stay as written (see ``placeholderKeys``); an unevaluable value shows as `⟨expression⟩`.
    public let route: String
    public let classPath: String
    public let methodPath: String
    public let conditions: SpringRequestConditions
    public let parameters: [SpringEndpointParameter]
    public let response: SpringEndpointResponse
    public var certainty: SpringCertainty
    public let confidence: SpringEndpointConfidence
    public let handlerLocation: SpringSourceLocation
    /// The mapping annotation that contributes the method path (it may be on an interface or superclass).
    public let mappingLocation: SpringSourceLocation
    public let classMappingLocation: SpringSourceLocation?
    public let controllerLocation: SpringSourceLocation
    /// The type that declares the method-level mapping, when it is not the controller itself.
    public let mappingDeclaredIn: String?
    /// The composed annotation the mapping came from (`com.acme.ApiGet`), when it is not a Spring annotation.
    public let composedFrom: String?
    /// Placeholder keys (`${api.base}`) in the route and the other mapping attributes.
    public let placeholderKeys: [String]
    public let requestBodyType: String?
    /// A JSON skeleton of the request body when its type is declared in the project's sources.
    public let requestBodySkeleton: String?
    /// Validation constraints that apply to the request: parameter annotations and the constraints on a validated body's fields.
    public let validations: [String]
    public var exceptionHandlers: [SpringExceptionHandlerRef]
    /// The `@RequestMapping(name = …)` value.
    public let mappingName: String?

    public var pathVariables: [String] { SpringRoute.variables(in: route).map(\.name) }
    public var controllerSimpleName: String { controller.split(separator: ".").last.map(String.init) ?? controller }
    public var methodsTitle: String { conditions.methods.isEmpty ? "ANY" : conditions.methods.joined(separator: ", ") }
    /// `GET /api/customers/{id}`; `ANY` when the mapping does not restrict the method.
    public var title: String { "\(methodsTitle) \(route)" }
    public var handlerTitle: String { "\(controllerSimpleName).\(handler)" }
}

public enum SpringEndpointDiagnosticCode {
    public static let ambiguous = "spring.endpoint.ambiguous-mapping"
    public static let ambiguousVariables = "spring.endpoint.ambiguous-variables"
    public static let malformedPattern = "spring.endpoint.malformed-pattern"
    public static let unknownPathVariable = "spring.endpoint.unknown-path-variable"
    public static let multipleMappings = "spring.endpoint.multiple-mappings"
    public static let duplicatePath = "spring.endpoint.duplicate-path"
    public static let multipleBodies = "spring.endpoint.multiple-request-bodies"
    public static let conflictingBinding = "spring.endpoint.conflicting-binding"
    public static let unusedMapping = "spring.endpoint.unregistered-controller"
}

// MARK: - Route algebra

/// Spring's path-pattern rules, as far as endpoint analysis needs them: composing a class and a method path, reading the
/// variables, validating the syntax and matching a concrete path. Strings are never concatenated blindly: `PathPattern.combine`
/// (the default parser since Spring Boot 2.6 and the only one in WebFlux) drops a trailing `/*`, collapses the separator and
/// treats an empty side as "no path".
public enum SpringRoute {
    public struct Variable: Hashable, Sendable {
        public let name: String
        /// The regular expression after `:`, if any.
        public let regex: String?
        /// `{*rest}`: captures the remaining path.
        public let capturesRest: Bool
        /// UTF-16 range of the whole `{…}` in the pattern.
        public let range: Range<Int>
    }

    public struct Problem: Hashable, Sendable {
        public enum Severity: Hashable, Sendable { case error, warning }
        public let severity: Severity
        public let message: String
    }

    /// `foo` → `/foo`; `` stays empty (it is the "no path" mapping, shown as `/`).
    /// A path that starts with a `${placeholder}` is left alone: Spring resolves the placeholder first, and its value decides.
    public static func prependSlash(_ path: String) -> String {
        path.isEmpty || path.hasPrefix("/") || path.hasPrefix("${") ? path : "/" + path
    }

    /// `PathPattern.combine` for the common shapes: `/api` + `/x` → `/api/x`; `/api/` + `/x` → `/api/x`; `/a/*` + `/b` → `/a/b`;
    /// an empty side yields the other. A leading `/**` cannot be extended in a PathPattern, so it is kept and
    /// ``validate(_:)`` reports it.
    public static func combine(_ lhs: String, _ rhs: String) -> String {
        let a = prependSlash(lhs), b = prependSlash(rhs)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        var head = a
        if head.hasSuffix("/*") && !head.hasSuffix("/**") { head.removeLast(2) }
        if head.hasSuffix("/") && b.hasPrefix("/") { return head + b.dropFirst() }
        if !head.hasSuffix("/") && !b.hasPrefix("/") { return head + "/" + b }
        return head + b
    }

    /// The route as displayed: empty is the root.
    public static func display(_ route: String) -> String { route.isEmpty ? "/" : route }

    /// Scans a pattern, skipping `${…}` and `#{…}` (placeholders and SpEL), and reports `{name}`, `{name:regex}` and `{*rest}`.
    public static func variables(in pattern: String) -> [Variable] {
        var out: [Variable] = []
        scan(pattern) { event in
            if case .variable(let v) = event { out.append(v) }
        }
        return out
    }

    /// The keys of `${key}` / `${key:default}` placeholders.
    public static func placeholderKeys(in text: String) -> [String] {
        SpringPlaceholder.scan(text).map(\.key)
    }

    /// The pattern with variable names removed (`/a/{x}` → `/a/{}`), which is what decides whether two patterns match the same
    /// requests with the same specificity.
    public static func structure(_ pattern: String) -> String {
        var out = ""
        let u = Array(pattern.utf16)
        var utf16Cursor = 0
        let vars = variables(in: pattern)
        for v in vars {
            out += String(utf16CodeUnits: Array(u[utf16Cursor..<v.range.lowerBound]), count: v.range.lowerBound - utf16Cursor)
            out += v.capturesRest ? "{*}" : (v.regex.map { "{:\($0)}" } ?? "{}")
            utf16Cursor = v.range.upperBound
        }
        out += String(utf16CodeUnits: Array(u[utf16Cursor...]), count: u.count - utf16Cursor)
        return out
    }

    /// Syntax problems the Spring parsers reject or that defeat the pattern's purpose.
    public static func validate(_ pattern: String) -> [Problem] {
        var problems: [Problem] = []
        var depth = 0
        var sawEmptyName = false
        var openedAt = 0
        let chars = Array(pattern.utf16)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if (c == 0x24 || c == 0x23), i + 1 < chars.count, chars[i + 1] == 0x7B {   // ${ or #{
                var d = 1; i += 2
                while i < chars.count, d > 0 { if chars[i] == 0x7B { d += 1 } else if chars[i] == 0x7D { d -= 1 }; i += 1 }
                if d > 0 { problems.append(Problem(severity: .error, message: "Unclosed '\(c == 0x24 ? "${" : "#{")' placeholder in the path.")) }
                continue
            }
            if c == 0x7B {
                if depth == 0 {
                    openedAt = i
                    var j = i + 1
                    if j < chars.count, chars[j] == 0x2A { j += 1 }
                    if j >= chars.count || chars[j] == 0x7D || chars[j] == 0x3A { sawEmptyName = true }
                }
                depth += 1
            } else if c == 0x7D {
                if depth == 0 { problems.append(Problem(severity: .error, message: "Unmatched '}' in the path pattern.")) } else { depth -= 1 }
            }
            i += 1
        }
        if depth > 0 {
            problems.append(Problem(severity: .error, message: "Unclosed '{' at position \(openedAt) of the path pattern."))
        }
        if sawEmptyName { problems.append(Problem(severity: .error, message: "A path variable needs a name: write {name}.")) }
        let segments = pattern.split(separator: "/", omittingEmptySubsequences: true)
        for (index, segment) in segments.enumerated() where index < segments.count - 1 {
            if segment == "**" {
                problems.append(Problem(severity: .warning, message: "'**' is only allowed at the end of a path pattern by PathPatternParser (the default since Spring Boot 2.6 and the only one in WebFlux)."))
            }
            if segment.hasPrefix("{*") && segment.hasSuffix("}") {
                problems.append(Problem(severity: .error, message: "'\(segment)' captures the rest of the path, so nothing may follow it."))
            }
        }
        let names = variables(in: pattern).map(\.name).filter { !$0.isEmpty }
        if let dup = Dictionary(grouping: names, by: { $0 }).first(where: { $0.value.count > 1 }) {
            problems.append(Problem(severity: .warning, message: "The path variable '\(dup.key)' appears more than once."))
        }
        return problems
    }

    /// Whether the concrete request path `path` (no query, no host) is matched by `pattern`.
    public static func matches(pattern: String, path: String) -> Bool {
        let pat = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let req = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return match(pat[...], req[...])
    }

    private static func match(_ pat: ArraySlice<String>, _ req: ArraySlice<String>) -> Bool {
        guard let head = pat.first else { return req.isEmpty }
        if head == "**" || (head.hasPrefix("{*") && head.hasSuffix("}")) { return true }   // matches whatever remains
        guard let r = req.first else { return false }
        return segmentMatches(head, r) && match(pat.dropFirst(), req.dropFirst())
    }

    private static func segmentMatches(_ pattern: String, _ value: String) -> Bool {
        if pattern == value || pattern == "*" { return true }
        if value.hasPrefix("{{") || value.hasPrefix("${") { return true }   // an unresolved template in the caller
        guard pattern.contains("{") || pattern.contains("*") || pattern.contains("?") else { return false }
        var regex = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            if c == "$", pattern[pattern.index(after: i)...].hasPrefix("{"), let close = pattern[i...].firstIndex(of: "}") {
                regex += "[^/]*"; i = pattern.index(after: close); continue
            }
            if c == "{" {
                var depth = 0, j = i
                while j < pattern.endIndex { if pattern[j] == "{" { depth += 1 } else if pattern[j] == "}" { depth -= 1; if depth == 0 { break } }; j = pattern.index(after: j) }
                let inner = j < pattern.endIndex ? String(pattern[pattern.index(after: i)..<j]) : String(pattern[pattern.index(after: i)...])
                if let colon = inner.firstIndex(of: ":") { regex += "(?:" + inner[inner.index(after: colon)...] + ")" } else { regex += "[^/]+" }
                i = j < pattern.endIndex ? pattern.index(after: j) : pattern.endIndex
                continue
            }
            if c == "*" { regex += "[^/]*" } else if c == "?" { regex += "[^/]" } else { regex += NSRegularExpression.escapedPattern(for: String(c)) }
            i = pattern.index(after: i)
        }
        regex += "$"
        return value.range(of: regex, options: .regularExpression) != nil
    }

    /// The part of the pattern before its first variable, wildcard or placeholder, for cheap pre-filtering.
    public static func literalPrefix(_ pattern: String) -> String {
        var out = ""
        for ch in pattern {
            if "{*?$#".contains(ch) { break }
            out.append(ch)
        }
        return out
    }

    // MARK: Scanner

    private enum Event { case variable(Variable) }

    private static func scan(_ pattern: String, _ body: (Event) -> Void) {
        let chars = Array(pattern.utf16)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if (c == 0x24 || c == 0x23), i + 1 < chars.count, chars[i + 1] == 0x7B {
                var d = 1; i += 2
                while i < chars.count, d > 0 { if chars[i] == 0x7B { d += 1 } else if chars[i] == 0x7D { d -= 1 }; i += 1 }
                continue
            }
            guard c == 0x7B else { i += 1; continue }
            let start = i
            var depth = 1; i += 1
            while i < chars.count, depth > 0 { if chars[i] == 0x7B { depth += 1 } else if chars[i] == 0x7D { depth -= 1 }; i += 1 }
            guard depth == 0 else { return }   // unclosed: ``validate`` reports it
            let inner = String(utf16CodeUnits: Array(chars[(start + 1)..<(i - 1)]), count: i - 1 - (start + 1))
            var name = inner, regex: String?
            if let colon = inner.firstIndex(of: ":") { name = String(inner[..<colon]); regex = String(inner[inner.index(after: colon)...]) }
            let rest = name.hasPrefix("*")
            if rest { name.removeFirst() }
            body(.variable(Variable(name: name.trimmingCharacters(in: .whitespaces), regex: regex, capturesRest: rest, range: start..<i)))
        }
    }
}
