import Foundation
import JavaIntelligence

/// Spring web annotations by their qualified names. The extractor matches what a name *resolves to* (imports, same package,
/// project annotation types), never the spelling alone, so a project's own `GetMapping` does not become an endpoint.
enum SpringWebAnnotations {
    static let package = "org.springframework.web.bind.annotation."
    /// Mapping annotations and the HTTP method each one implies (`nil`: the `method` attribute decides).
    static let mappings: [String: String?] = [
        "RequestMapping": nil, "GetMapping": "GET", "PostMapping": "POST", "PutMapping": "PUT",
        "PatchMapping": "PATCH", "DeleteMapping": "DELETE",
    ]
    static let bindings: [String: SpringEndpointParameter.Kind] = [
        "PathVariable": .pathVariable, "RequestParam": .requestParam, "RequestHeader": .requestHeader, "RequestBody": .requestBody,
        "RequestPart": .requestPart, "CookieValue": .cookie, "ModelAttribute": .modelAttribute, "MatrixVariable": .matrixVariable,
        "RequestAttribute": .requestAttribute, "SessionAttribute": .sessionAttribute,
    ]
    static let others: Set<String> = ["ResponseBody", "ResponseStatus", "ExceptionHandler", "CrossOrigin", "InitBinder"]
    /// Simple names the *bean* model never reads, so editing one does not rebuild a context (see `SpringProjectModel.beanSignature`).
    static let webOnly: Set<String> = Set(mappings.keys).union(bindings.keys).union(others).union(["Valid", "Validated"])

    static func isSpringWeb(_ qualified: String) -> Bool {
        guard qualified.hasPrefix(package) else { return false }
        let simple = String(qualified.dropFirst(package.count))
        return mappings[simple] != nil || mappings.keys.contains(simple) || bindings[simple] != nil || others.contains(simple)
            || simple == "ControllerAdvice" || simple == "RestControllerAdvice" || simple == "RestController"
    }

    static func simple(_ qualified: String) -> String? {
        qualified.hasPrefix(package) ? String(qualified.dropFirst(package.count)) : nil
    }

    static let validationPackages = ["jakarta.validation.constraints.", "javax.validation.constraints."]
    static let validationNames: Set<String> = [
        "NotNull", "NotBlank", "NotEmpty", "Size", "Min", "Max", "Positive", "PositiveOrZero", "Negative", "NegativeOrZero",
        "Email", "Pattern", "Past", "PastOrPresent", "Future", "FutureOrPresent", "Digits", "DecimalMin", "DecimalMax",
        "AssertTrue", "AssertFalse", "Null",
    ]
    static func isConstraint(_ qualified: String) -> Bool {
        validationPackages.contains { qualified.hasPrefix($0) && validationNames.contains(String(qualified.dropFirst($0.count))) }
    }
    static let validAnnotations: Set<String> = [
        "jakarta.validation.Valid", "javax.validation.Valid", "org.springframework.validation.annotation.Validated",
    ]

    static let mediaTypes: [String: String] = [
        "APPLICATION_JSON_VALUE": "application/json", "APPLICATION_XML_VALUE": "application/xml",
        "APPLICATION_FORM_URLENCODED_VALUE": "application/x-www-form-urlencoded", "MULTIPART_FORM_DATA_VALUE": "multipart/form-data",
        "TEXT_PLAIN_VALUE": "text/plain", "TEXT_HTML_VALUE": "text/html", "TEXT_XML_VALUE": "text/xml",
        "TEXT_EVENT_STREAM_VALUE": "text/event-stream", "APPLICATION_OCTET_STREAM_VALUE": "application/octet-stream",
        "APPLICATION_NDJSON_VALUE": "application/x-ndjson", "APPLICATION_PROBLEM_JSON_VALUE": "application/problem+json",
        "APPLICATION_PDF_VALUE": "application/pdf", "ALL_VALUE": "*/*", "IMAGE_PNG_VALUE": "image/png", "IMAGE_JPEG_VALUE": "image/jpeg",
        "APPLICATION_STREAM_JSON_VALUE": "application/stream+json", "APPLICATION_PROBLEM_XML_VALUE": "application/problem+xml",
    ]

    /// Parameter types Spring supplies itself: they are never part of the request's shape.
    static let infrastructure: Set<String> = [
        "HttpServletRequest", "HttpServletResponse", "HttpSession", "Principal", "Model", "ModelMap", "Locale", "BindingResult",
        "Errors", "Authentication", "UriComponentsBuilder", "ServerWebExchange", "ServerHttpRequest", "ServerHttpResponse",
        "WebRequest", "NativeWebRequest", "InputStream", "OutputStream", "Reader", "Writer", "HttpMethod", "TimeZone", "ZoneId",
        "SessionStatus", "RedirectAttributes", "HttpEntity", "RequestEntity", "ServletRequest", "ServletResponse", "Pageable",
        "Sort", "WebSession", "SecurityContext", "CsrfToken", "ServerRequest", "BindingResult",
    ]
    static let simpleValueTypes: Set<String> = [
        "String", "Integer", "Long", "Short", "Byte", "Boolean", "Double", "Float", "Character", "UUID", "BigDecimal", "BigInteger",
        "LocalDate", "LocalDateTime", "LocalTime", "Instant", "OffsetDateTime", "ZonedDateTime", "Date", "URI", "URL", "Locale",
        "Currency", "Duration", "Period", "int", "long", "short", "byte", "boolean", "double", "float", "char", "MultipartFile",
        "Part", "FilePart", "Resource",
    ]
}

/// What extracting one controller produced. It depends only on the controller's own file and the files of the types it extends,
/// implements or composes annotations from (`touched`), so editing anything else leaves it valid.
struct SpringControllerExtraction: Sendable {
    var endpoints: [SpringEndpoint] = []
    var diagnostics: [SpringDiagnostic] = []
    var handlers: [SpringExceptionHandlerRef] = []
    var touched: Set<URL> = []
}

/// Reads handler methods out of the project's declarations. It reuses ``SpringModelBuilder``'s name resolution (imports, same
/// package, nested types, project annotation types), so an annotation or a type means the same thing here as it does for beans.
struct SpringEndpointExtractor {
    typealias Ctx = SpringModelBuilder.Context

    private final class Touched { var urls = Set<URL>() }
    private let builder: SpringModelBuilder
    private let touched = Touched()

    init(builder: SpringModelBuilder) { self.builder = builder }

    // MARK: Mapping annotations

    private enum PathItem: Hashable { case literal(String), expression(String) }

    private struct Attrs {
        var paths: [PathItem] = []
        var methods: [String] = []
        var params: [String] = [], headers: [String] = [], consumes: [String] = [], produces: [String] = []
        var name: String?
        var reasons: [String] = []
    }

    private struct Mapping {
        let use: JavaAnnotationUse
        var attrs: Attrs
        let composed: String?
    }

    private func entry(_ qualified: String) -> (type: JavaAnnotatedType, ctx: Ctx)? {
        guard let e = builder.typeIndex[qualified] else { return nil }
        touched.urls.insert(e.ctx.url)
        return e
    }

    /// `"/a" + "/b"` and string-literal-only concatenations.
    private func literalConcatenation(_ expression: String) -> String? {
        var out = ""
        var inString = false, escaped = false, current = ""
        var sawPlus = false
        for ch in expression {
            if inString {
                if escaped { current.append(ch); escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false; out += current; current = "" } else { current.append(ch) }
            } else if ch == "\"" { inString = true } else if ch == "+" { sawPlus = true } else if !ch.isWhitespace { return nil }
        }
        return sawPlus && !inString ? out : nil
    }

    private func items(_ value: JavaAnnotationValue?) -> [PathItem] {
        guard let value else { return [] }
        switch value {
        case .string(let s): return [.literal(s)]
        case .array(let a): return a.flatMap(items)
        case .classLiteral(let c): return [.expression(c + ".class")]
        case .expression(let e):
            if let joined = literalConcatenation(e) { return [.literal(joined)] }
            let last = e.split(separator: ".").last.map(String.init) ?? e
            if let media = SpringWebAnnotations.mediaTypes[last] { return [.literal(media)] }
            return [.expression(e)]
        }
    }

    private func strings(_ value: JavaAnnotationValue?, _ attrs: inout Attrs, _ what: String) -> [String] {
        items(value).map {
            switch $0 {
            case .literal(let s): return s
            case .expression(let e): attrs.reasons.append("\(what) uses \(e)"); return "⟨\(e)⟩"
            }
        }
    }

    private func methodNames(_ value: JavaAnnotationValue?, _ attrs: inout Attrs) -> [String] {
        items(value).compactMap {
            switch $0 {
            case .literal(let s): return s.uppercased()
            case .expression(let e):
                let last = (e.split(separator: ".").last.map(String.init) ?? e).uppercased()
                if SpringRequestConditions.methodOrder.contains(last) { return last }
                attrs.reasons.append("method uses \(e)")
                return nil
            }
        }
    }

    private func attrs(of use: JavaAnnotationUse, implied: String?) -> Attrs {
        var a = Attrs()
        a.paths = items(use["path"] ?? use["value"])
        a.methods = implied.map { [$0] } ?? methodNames(use["method"], &a)
        a.params = strings(use["params"], &a, "params")
        a.headers = strings(use["headers"], &a, "headers")
        a.consumes = strings(use["consumes"], &a, "consumes")
        a.produces = strings(use["produces"], &a, "produces")
        a.name = use["name"]?.scalarText
        return a
    }

    private func aliasTarget(_ element: JavaDeclaredAnnotationElement, _ ctx: Ctx) -> (annotation: String, attribute: String)? {
        guard let alias = element.annotations.first(where: { $0.simpleName == "AliasFor" }),
              let target = alias["annotation"]?.classLiterals.first else { return nil }
        let attribute = alias["attribute"]?.scalarText ?? alias["value"]?.scalarText ?? element.name
        return (target.split(separator: ".").last.map(String.init) ?? target, attribute)
    }

    /// The mapping an annotation contributes: a Spring mapping annotation directly, or a project annotation that is
    /// (transitively) meta-annotated with one, with its `@AliasFor` attributes merged into the meta-annotation as Spring does.
    private func mapping(_ use: JavaAnnotationUse, _ ctx: Ctx, depth: Int = 0, visiting: Set<String> = []) -> Mapping? {
        let q = builder.qualifyAnnotation(use.name, ctx)
        if let simple = SpringWebAnnotations.simple(q), let implied = SpringWebAnnotations.mappings[simple] {
            return Mapping(use: use, attrs: attrs(of: use, implied: implied), composed: nil)
        }
        guard depth < 6, !visiting.contains(q), let e = entry(q), e.type.kind == .annotationKind else { return nil }
        for meta in e.type.annotations {
            var merged = meta.arguments
            let metaSimple = meta.simpleName
            for element in e.type.annotationElements {
                guard let target = aliasTarget(element, e.ctx), target.annotation == metaSimple,
                      let value = use[element.name] ?? element.defaultValue else { continue }
                merged[target.attribute] = value
            }
            let overlay = JavaAnnotationUse(name: meta.name, arguments: merged, byteRange: meta.byteRange)
            if var inner = mapping(overlay, e.ctx, depth: depth + 1, visiting: visiting.union([q])) {
                inner = Mapping(use: use, attrs: inner.attrs, composed: inner.composed ?? q)
                return inner
            }
        }
        return nil
    }

    private func mappings(_ annotations: [JavaAnnotationUse], _ ctx: Ctx) -> [Mapping] {
        annotations.compactMap { mapping($0, ctx) }
    }

    private func webSimple(_ use: JavaAnnotationUse, _ ctx: Ctx) -> String? {
        SpringWebAnnotations.simple(builder.qualifyAnnotation(use.name, ctx))
    }

    // MARK: Hierarchy

    private func projectName(of ref: JavaTypeRef, _ e: (type: JavaAnnotatedType, ctx: Ctx)) -> String? {
        let name = builder.resolve(ref, e.ctx, enclosing: e.type.qualifiedName).name
        return builder.typeIndex[name] == nil ? nil : name
    }

    /// Supertypes in Spring's search order for merged annotations: interfaces, then the superclass.
    private func supertypes(of q: String) -> [String] {
        guard let e = entry(q) else { return [] }
        var out: [String] = []
        for i in e.type.interfaces { if let n = projectName(of: i, e) { out.append(n) } }
        if let s = e.type.superclass, let n = projectName(of: s, e) { out.append(n) }
        return out
    }

    /// `T`, then everything it extends or implements, depth-first in find order, each type once.
    private func linearisation(of q: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        func visit(_ n: String) {
            guard seen.insert(n).inserted else { return }
            out.append(n)
            for s in supertypes(of: n) { visit(s) }
        }
        visit(q)
        return out
    }

    private func signature(_ m: JavaDeclaredMethod, in e: (type: JavaAnnotatedType, ctx: Ctx)) -> String {
        "\(m.name)(\(m.parameters.map { builder.resolve($0.type, e.ctx, enclosing: e.type.qualifiedName).name }.joined(separator: ",")))"
    }

    // MARK: Types as text

    private func display(_ t: SpringType) -> String { SpringModelBuilder.display(t) }

    private static let streamWrappers: Set<String> = ["Flux", "Publisher", "Stream", "Observable", "Flowable", "SseEmitter"]
    private static let wrappers: Set<String> = [
        "Mono", "Flux", "Publisher", "ResponseEntity", "HttpEntity", "CompletableFuture", "CompletionStage", "Callable", "DeferredResult",
        "ListenableFuture", "Single", "Maybe", "Observable", "Flowable", "WebAsyncTask",
    ]
    static let reactiveTypes: Set<String> = ["Mono", "Flux", "Publisher", "Single", "Maybe", "Observable", "Flowable"]

    private func response(of m: JavaDeclaredMethod, type: SpringType, hasResponseBody: Bool, status: String?) -> SpringEndpointResponse {
        var current = type
        var wrappers: [String] = []
        var stream = false
        while Self.wrappers.contains(current.simpleName), builder.typeIndex[current.name] == nil, let inner = current.arguments.first {
            wrappers.append(current.simpleName)
            if Self.streamWrappers.contains(current.simpleName) { stream = true }
            current = inner
        }
        if Self.wrappers.contains(current.simpleName), builder.typeIndex[current.name] == nil, current.arguments.isEmpty {
            wrappers.append(current.simpleName)   // raw `ResponseEntity`, `Mono`: the payload is unknown
            let isBody = hasResponseBody || wrappers.contains(where: { $0 == "ResponseEntity" || $0 == "HttpEntity" })
            return SpringEndpointResponse(declared: display(type), payload: nil, wrappers: wrappers, isStream: stream, isBody: isBody, status: status)
        }
        let isVoid = current.name == "void" || current.name == "java.lang.Void" || current.simpleName == "Void"
        let isEntity = wrappers.contains { $0 == "ResponseEntity" || $0 == "HttpEntity" }
        let isBody = hasResponseBody || isEntity || stream
        // Without `@ResponseBody` a `String` is a view name in a plain `@Controller`.
        let isView = !isBody && (current.simpleName == "String" || current.simpleName == "ModelAndView" || current.simpleName == "View")
        return SpringEndpointResponse(
            declared: display(type), payload: isVoid || isView ? nil : display(current), wrappers: wrappers, isStream: stream,
            isBody: isBody && !isVoid, status: status)
    }

    // MARK: Parameters

    private func isSimpleValue(_ t: SpringType) -> Bool {
        var current = t
        if current.simpleName == "Optional", let inner = current.arguments.first { current = inner }
        if SpringWebAnnotations.simpleValueTypes.contains(current.simpleName), builder.typeIndex[current.name] == nil { return true }
        if let e = builder.typeIndex[current.name], e.type.kind == .enumKind { return true }
        if current.name.hasSuffix("[]") { return current.arguments.first.map(isSimpleValue) ?? false }
        if ["List", "Set", "Collection"].contains(current.simpleName), let inner = current.arguments.first { return isSimpleValue(inner) }
        return false
    }

    private func render(_ use: JavaAnnotationUse) -> String {
        let args = use.arguments.keys.sorted().map { key -> String in
            let value = use.arguments[key]!
            let text: String
            switch value {
            case .string(let s): text = "\"\(s)\""
            case .classLiteral(let c): text = c + ".class"
            case .expression(let e): text = e
            case .array(let a): text = "{" + a.map { v -> String in
                if case .string(let s) = v { return "\"\(s)\"" }
                return v.scalarText ?? "…"
            }.joined(separator: ", ") + "}"
            }
            return key == "value" && use.arguments.count == 1 ? text : "\(key) = \(text)"
        }
        return "@\(use.simpleName)" + (args.isEmpty ? "" : "(\(args.joined(separator: ", ")))")
    }

    private func parameters(of method: JavaDeclaredMethod, in e: (type: JavaAnnotatedType, ctx: Ctx), fallback: JavaDeclaredMethod?,
                            fallbackEntry: (type: JavaAnnotatedType, ctx: Ctx)?) -> (params: [SpringEndpointParameter], extras: [(JavaDeclaredParameter, [JavaAnnotationUse], Ctx)]) {
        var out: [SpringEndpointParameter] = []
        var raw: [(JavaDeclaredParameter, [JavaAnnotationUse], Ctx)] = []
        for (i, p) in method.parameters.enumerated() {
            var annotations = p.annotations
            var ctx = e.ctx
            if let fb = fallback, let fbe = fallbackEntry, i < fb.parameters.count,
               !annotations.contains(where: { webSimple($0, e.ctx) != nil && SpringWebAnnotations.bindings[webSimple($0, e.ctx)!] != nil }) {
                annotations += fb.parameters[i].annotations
                if !fb.parameters[i].annotations.isEmpty { ctx = fbe.ctx }
            }
            raw.append((p, annotations, ctx))
            let type = builder.resolve(p.type, e.ctx, enclosing: e.type.qualifiedName)
            var kind: SpringEndpointParameter.Kind?
            var binding: JavaAnnotationUse?
            for a in annotations {
                if let s = webSimple(a, e.ctx) ?? webSimple(a, ctx), let k = SpringWebAnnotations.bindings[s] { kind = k; binding = a; break }
            }
            var implicit = false
            if kind == nil {
                if SpringWebAnnotations.infrastructure.contains(type.simpleName) { continue }
                if annotations.contains(where: { webSimple($0, ctx) == nil && !SpringWebAnnotations.isConstraint(builder.qualifyAnnotation($0.name, ctx))
                    && !SpringWebAnnotations.validAnnotations.contains(builder.qualifyAnnotation($0.name, ctx)) }) { continue }   // e.g. @AuthenticationPrincipal
                implicit = true
                kind = isSimpleValue(type) ? .requestParam : .modelAttribute
            }
            var validations: [String] = []
            for a in annotations {
                let q = builder.qualifyAnnotation(a.name, ctx)
                if SpringWebAnnotations.isConstraint(q) || SpringWebAnnotations.validAnnotations.contains(q) { validations.append(render(a)) }
            }
            let explicit = binding.flatMap { ($0["name"] ?? $0["value"])?.scalarText }
            let defaultValue = binding?["defaultValue"]?.scalarText
            var required = binding?["required"]?.scalarText != "false" && defaultValue == nil
            if type.simpleName == "Optional" || type.simpleName == "ObjectProvider" { required = false }
            if implicit { required = false }
            let bindsAll = (type.simpleName == "Map" || type.simpleName == "MultiValueMap") && explicit == nil
            let target = type.simpleName == "Optional" ? (type.arguments.first ?? type) : type
            out.append(SpringEndpointParameter(
                name: p.name, bindingName: explicit ?? p.name, kind: kind!, type: display(target), isRequired: required,
                defaultValue: defaultValue, isImplicit: implicit, bindsAll: bindsAll, validations: validations,
                location: SpringSourceLocation(url: ctx.url, byteRange: p.byteRange), nameRange: p.nameRange,
                annotationRange: binding?.byteRange))
        }
        return (out, raw)
    }

    // MARK: JSON skeleton

    private indirect enum JSON { case string(String), number(String), bool(Bool), null, array([JSON]), object([(String, JSON)]) }

    private func skeleton(_ t: SpringType, depth: Int, visiting: Set<String>) -> JSON {
        var type = t
        if type.simpleName == "Optional", let inner = type.arguments.first { type = inner }
        let n = type.simpleName
        switch n {
        case "String", "char", "Character", "CharSequence": return .string("string")
        case "int", "long", "short", "byte", "Integer", "Long", "Short", "Byte", "BigInteger": return .number("0")
        case "double", "float", "Double", "Float", "BigDecimal", "Number": return .number("0.0")
        case "boolean", "Boolean": return .bool(false)
        case "UUID": return .string("00000000-0000-0000-0000-000000000000")
        case "LocalDate": return .string("2000-01-01")
        case "LocalDateTime": return .string("2000-01-01T00:00:00")
        case "LocalTime": return .string("00:00:00")
        case "Instant", "OffsetDateTime", "ZonedDateTime", "Date": return .string("2000-01-01T00:00:00Z")
        case "Map", "HashMap", "LinkedHashMap", "TreeMap": return .object([])
        case "List", "Set", "Collection", "ArrayList", "Iterable", "SortedSet", "LinkedList":
            return .array(type.arguments.first.map { [skeleton($0, depth: depth + 1, visiting: visiting)] } ?? [])
        default: break
        }
        if type.name.hasSuffix("[]"), let inner = type.arguments.first { return .array([skeleton(inner, depth: depth + 1, visiting: visiting)]) }
        guard let e = entry(type.name), depth < 4, !visiting.contains(type.name) else { return .object([]) }
        if e.type.kind == .enumKind { return .string("\(type.simpleName)") }
        var fields: [(String, JSON)] = []
        var chain = [type.name]
        if let s = e.type.superclass, let name = projectName(of: s, e) { chain.insert(contentsOf: linearisation(of: name).reversed(), at: 0) }
        for owner in chain {
            guard let oe = entry(owner) else { continue }
            for f in oe.type.fields where !f.modifiers.contains(.staticFlag) {
                if f.annotations.contains(where: { $0.simpleName == "JsonIgnore" }) { continue }
                let name = f.annotations.first(where: { $0.simpleName == "JsonProperty" }).flatMap { ($0["value"] ?? $0["name"])?.scalarText } ?? f.name
                fields.append((name, skeleton(builder.resolve(f.type, oe.ctx, enclosing: oe.type.qualifiedName), depth: depth + 1, visiting: visiting.union([type.name]))))
            }
        }
        return .object(fields)
    }

    private func render(_ json: JSON, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent + 1), close = String(repeating: "  ", count: indent)
        switch json {
        case .string(let s): return "\"\(s)\""
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let items):
            return items.isEmpty ? "[]" : "[\n" + items.map { pad + render($0, indent: indent + 1) }.joined(separator: ",\n") + "\n\(close)]"
        case .object(let pairs):
            return pairs.isEmpty ? "{}" : "{\n" + pairs.map { "\(pad)\"\($0.0)\": \(render($0.1, indent: indent + 1))" }.joined(separator: ",\n") + "\n\(close)}"
        }
    }

    /// Constraint annotations on the fields of a validated body type, as `field: @NotBlank @Size(max = 50)`.
    private func fieldConstraints(of type: SpringType) -> [String] {
        guard let e = entry(type.name) else { return [] }
        var out: [String] = []
        for f in e.type.fields {
            let found = f.annotations.filter { SpringWebAnnotations.isConstraint(builder.qualifyAnnotation($0.name, e.ctx)) }
            if !found.isEmpty { out.append("\(type.simpleName).\(f.name): " + found.map { render($0) }.joined(separator: " ")) }
        }
        return out
    }

    // MARK: Extraction

    private func location(_ ctx: Ctx, _ range: Range<Int>) -> SpringSourceLocation { SpringSourceLocation(url: ctx.url, byteRange: range) }

    /// Every endpoint of `controller`, with the structural problems found while reading its mappings.
    func extract(controller q: String, isRest: Bool) -> SpringControllerExtraction? {
        touched.urls.removeAll()
        guard let own = entry(q) else { return nil }
        var result = SpringControllerExtraction()
        let chain = linearisation(of: q)
        let controllerLocation = location(own.ctx, own.type.nameRange)

        // Class-level mapping: the first mapping annotation found on the class, its interfaces or its superclasses.
        var classMapping: (mapping: Mapping, owner: String, ctx: Ctx)?
        for name in chain {
            guard let e = entry(name) else { continue }
            if let m = mappings(e.type.annotations, e.ctx).first { classMapping = (m, name, e.ctx); break }
        }
        var diagnosticKeys = Set<String>()
        func report(_ severity: SpringDiagnosticSeverity, _ code: String, _ message: String, _ loc: SpringSourceLocation, suggestion: String? = nil) {
            guard diagnosticKeys.insert("\(code)|\(loc.url.path)|\(loc.byteRange.lowerBound)|\(message)").inserted else { return }
            result.diagnostics.append(SpringDiagnostic(severity: severity, code: code, message: message, location: loc, related: [], suggestion: suggestion))
        }

        func checkMappingAnnotations(_ annotations: [JavaAnnotationUse], _ ctx: Ctx, what: String) {
            let found = mappings(annotations, ctx)
            if found.count > 1 {
                for ignored in found.dropFirst() {
                    report(.warning, SpringEndpointDiagnosticCode.multipleMappings,
                           "Spring uses only the first mapping annotation on a \(what) (@\(found[0].use.simpleName)); @\(ignored.use.simpleName) is ignored.",
                           location(ctx, ignored.use.byteRange))
                }
            }
            if let m = found.first {
                var seen = Set<String>()
                for item in m.attrs.paths {
                    if case .literal(let p) = item {
                        let key = SpringRoute.prependSlash(p)
                        if !seen.insert(key).inserted {
                            report(.warning, SpringEndpointDiagnosticCode.duplicatePath, "The path '\(SpringRoute.display(key))' is listed more than once in @\(m.use.simpleName).",
                                   location(ctx, m.use.byteRange))
                        }
                        for problem in SpringRoute.validate(key) {
                            report(problem.severity == .error ? .error : .warning, SpringEndpointDiagnosticCode.malformedPattern,
                                   "Invalid path pattern '\(key)': \(problem.message)", location(ctx, m.use.byteRange))
                        }
                    }
                }
            }
        }
        if let cm = classMapping, let e = entry(cm.owner) { checkMappingAnnotations(e.type.annotations, e.ctx, what: "class") }

        // Handler methods: every method of the class and its superclasses (the most specific declaration of each signature).
        var handlerOrder: [String] = []
        var implementation: [String: (method: JavaDeclaredMethod, owner: String)] = [:]
        for name in chain {
            guard let e = entry(name) else { continue }
            for m in e.type.methods where !m.isConstructor {
                let sig = signature(m, in: e)
                if implementation[sig] == nil {
                    implementation[sig] = (m, name)
                    handlerOrder.append(sig)
                }
            }
        }
        let typeAnnotationsResponseBody = chain.contains { name in entry(name)?.type.annotations.contains { $0.simpleName == "ResponseBody" } ?? false }

        for sig in handlerOrder {
            guard let impl = implementation[sig], let implEntry = entry(impl.owner) else { continue }
            let m = impl.method
            guard !m.modifiers.contains(.staticFlag), !m.modifiers.contains(.privateFlag) else { continue }
            // The mapping: on this method, else on the nearest overridden declaration.
            var found: (mapping: Mapping, owner: String, method: JavaDeclaredMethod, ctx: Ctx)?
            for name in chain {
                guard let e = entry(name), let candidate = e.type.methods.first(where: { !$0.isConstructor && signature($0, in: e) == sig }) else { continue }
                if let first = mappings(candidate.annotations, e.ctx).first { found = (first, name, candidate, e.ctx); break }
            }
            if let he = entry(impl.owner) {
                // Exception handlers declared on the controller (or its supertypes) answer for all its endpoints.
                if m.annotations.contains(where: { webSimple($0, he.ctx) == "ExceptionHandler" }),
                   let ann = m.annotations.first(where: { webSimple($0, he.ctx) == "ExceptionHandler" }) {
                    var exceptions = (ann["value"] ?? ann["exception"])?.classLiterals ?? []
                    if exceptions.isEmpty, let first = m.parameters.first { exceptions = [builder.resolve(first.type, he.ctx, enclosing: he.type.qualifiedName).simpleName] }
                    result.handlers.append(SpringExceptionHandlerRef(
                        method: m.name, owner: impl.owner, exceptions: exceptions, scope: .controller,
                        location: location(he.ctx, m.nameRange)))
                }
            }
            guard let found else { continue }
            checkMappingAnnotations(found.method.annotations, found.ctx, what: "method")

            let source = found.owner == impl.owner ? nil : (method: found.method, entry: entry(found.owner))
            let (params, rawParams) = parameters(of: m, in: implEntry, fallback: source?.method, fallbackEntry: source?.entry)

            // Compose path and conditions the way `RequestMappingInfo.combine` does.
            let c = classMapping?.mapping.attrs ?? Attrs()
            let methodAttrs = found.mapping.attrs
            var conditions = SpringRequestConditions()
            conditions.methods = SpringRequestConditions.sortMethods(c.methods + methodAttrs.methods)
            conditions.params = Array(Set(c.params + methodAttrs.params)).sorted()
            conditions.headers = Array(Set(c.headers + methodAttrs.headers)).sorted()
            conditions.consumes = methodAttrs.consumes.isEmpty ? c.consumes : methodAttrs.consumes
            conditions.produces = methodAttrs.produces.isEmpty ? c.produces : methodAttrs.produces
            var reasons = c.reasons + methodAttrs.reasons

            func text(_ item: PathItem) -> String {
                switch item {
                case .literal(let s): return s
                case .expression(let e): reasons.append("path uses \(e)"); return "⟨\(e)⟩"
                }
            }
            let classPaths = c.paths.isEmpty ? [""] : c.paths.map(text)
            let methodPaths = methodAttrs.paths.isEmpty ? [""] : methodAttrs.paths.map(text)

            let returnType = builder.resolve(m.returnType, implEntry.ctx, enclosing: implEntry.type.qualifiedName)
            let statusUse = m.annotations.first { webSimple($0, implEntry.ctx) == "ResponseStatus" }
            let status = statusUse.flatMap { ($0["value"] ?? $0["code"])?.scalarText }.map { $0.split(separator: ".").last.map(String.init) ?? $0 }
            let hasBody = isRest || typeAnnotationsResponseBody || m.annotations.contains { webSimple($0, implEntry.ctx) == "ResponseBody" }
            let responseShape = response(of: m, type: returnType, hasResponseBody: hasBody, status: status)

            // Request body type, skeleton and validations.
            var requestBodyType: String?, skeletonText: String?
            var validations: [String] = []
            let bodyParams = params.filter { $0.kind == .requestBody }
            if let bodyParam = bodyParams.first, let index = m.parameters.firstIndex(where: { $0.name == bodyParam.name }) {
                var t = builder.resolve(m.parameters[index].type, implEntry.ctx, enclosing: implEntry.type.qualifiedName)
                while ["Mono", "Flux", "HttpEntity", "RequestEntity", "Optional", "Publisher"].contains(t.simpleName), builder.typeIndex[t.name] == nil,
                      let inner = t.arguments.first { t = inner }
                requestBodyType = display(t)
                if SpringWebAnnotations.simpleValueTypes.contains(t.simpleName) || entry(t.name) != nil || t.simpleName == "List" || t.simpleName == "Map" {
                    skeletonText = render(skeleton(t, depth: 0, visiting: []))
                }
                if bodyParam.validations.contains(where: { $0.contains("Valid") }) { validations += fieldConstraints(of: t) }
            }
            for p in params { validations += p.validations.map { "\(p.name): \($0)" } }

            if bodyParams.count > 1 {
                report(.warning, SpringEndpointDiagnosticCode.multipleBodies,
                       "\(m.name)() has \(bodyParams.count) @RequestBody parameters; the request body can only be read once.", bodyParams[1].location)
            }
            for p in params where p.kind != .modelAttribute {
                guard p.annotationRange != nil else { continue }
                let n = rawParams.first { $0.0.name == p.name }?.1.filter {
                    (webSimple($0, implEntry.ctx).flatMap { SpringWebAnnotations.bindings[$0] }) != nil
                }.count ?? 0
                if n > 1 {
                    report(.warning, SpringEndpointDiagnosticCode.conflictingBinding,
                           "Parameter '\(p.name)' has more than one binding annotation; Spring uses only the first.", p.location)
                }
            }

            let placeholderKeys = Array(Set(
                (c.paths + methodAttrs.paths).flatMap { item -> [String] in
                    if case .literal(let s) = item { return SpringRoute.placeholderKeys(in: s) } else { return [] }
                } + (c.produces + c.consumes + methodAttrs.produces + methodAttrs.consumes + c.headers + methodAttrs.headers).flatMap(SpringRoute.placeholderKeys(in:))
            )).sorted()

            let confidence: SpringEndpointConfidence = reasons.isEmpty ? .exact : .partial(reasons: Array(Set(reasons)).sorted())

            var handlerLocation = location(implEntry.ctx, m.nameRange)
            if implEntry.ctx.url == own.ctx.url { handlerLocation = location(own.ctx, m.nameRange) }
            let stackGuess: SpringWebStack = {
                let reactive = SpringEndpointExtractor.reactiveTypes.contains(returnType.simpleName)
                    || params.contains { SpringEndpointExtractor.reactiveTypes.contains($0.type.split(separator: "<").first.map { String($0.split(separator: ".").last ?? "") } ?? "") }
                return reactive ? .webflux : .unknown
            }()
            var seenRoutes = Set<String>()
            var index = 0
            for cp in classPaths {
                for mp in methodPaths {
                    let route = SpringRoute.combine(cp, mp)
                    if !seenRoutes.insert(route).inserted { index += 1; continue }
                    let local = "\(q)#\(sig)#\(index)"
                    index += 1
                    var endpointValidations = validations
                    endpointValidations = Array(NSOrderedSet(array: endpointValidations)) as? [String] ?? endpointValidations
                    result.endpoints.append(SpringEndpoint(
                        id: SpringEndpointID(raw: local), contextID: "", module: nil, stack: stackGuess, controller: q, handler: m.name,
                        handlerSignature: sig, route: SpringRoute.display(route), classPath: cp, methodPath: mp, conditions: conditions,
                        parameters: params, response: responseShape, certainty: .certain, confidence: confidence,
                        handlerLocation: handlerLocation, mappingLocation: location(found.ctx, found.mapping.use.byteRange),
                        classMappingLocation: classMapping.map { location($0.ctx, $0.mapping.use.byteRange) },
                        controllerLocation: controllerLocation, mappingDeclaredIn: found.owner == q ? nil : found.owner,
                        composedFrom: found.mapping.composed, placeholderKeys: placeholderKeys, requestBodyType: requestBodyType,
                        requestBodySkeleton: skeletonText, validations: endpointValidations, exceptionHandlers: [], mappingName: methodAttrs.name))
                }
            }
            // Path variables: a `@PathVariable` the route does not declare fails at request time with a 500.
            let routes = result.endpoints.filter { $0.controller == q && $0.handlerSignature == sig }.map(\.route)
            if confidence.isExact, !routes.isEmpty {
                let declared = routes.map { Set(SpringRoute.variables(in: $0).map(\.name)) }
                let bound = Set(params.filter { $0.kind == .pathVariable && !$0.bindsAll }.map(\.bindingName))
                for p in params where p.kind == .pathVariable && !p.bindsAll && p.isRequired {
                    guard declared.allSatisfy({ !$0.contains(p.bindingName) }) else { continue }
                    let free = declared.first.map { $0.subtracting(bound).sorted() } ?? []
                    let known = (declared.first ?? []).sorted()
                    report(.error, SpringEndpointDiagnosticCode.unknownPathVariable,
                           "No path variable '{\(p.bindingName)}' in \(routes[0])" + (known.isEmpty ? "." : ". The mapping declares: \(known.map { "{\($0)}" }.joined(separator: ", ")).")
                           + (free.count == 1 ? " Did you mean {\(free[0])}?" : ""), p.location, suggestion: free.count == 1 ? free[0] : nil)
                }
            }
        }
        result.touched = touched.urls
        return result
    }

    /// `@ExceptionHandler` methods of an advice class, with the controllers its selectors admit.
    func adviceHandlers(advice q: String) -> (refs: [SpringExceptionHandlerRef], selector: AdviceSelector, touched: Set<URL>)? {
        touched.urls.removeAll()
        guard let e = entry(q) else { return nil }
        var selector = AdviceSelector()
        for use in e.type.annotations {
            let simple = SpringWebAnnotations.simple(builder.qualifyAnnotation(use.name, e.ctx))
            guard simple == "ControllerAdvice" || simple == "RestControllerAdvice" else { continue }
            var scratch = Attrs()
            selector.packages = strings(use["basePackages"] ?? use["value"], &scratch, "basePackages")
            selector.packageClasses = use["basePackageClasses"]?.classLiterals ?? []
            selector.assignable = use["assignableTypes"]?.classLiterals ?? []
            selector.hasAnnotationSelector = use["annotations"] != nil
        }
        var refs: [SpringExceptionHandlerRef] = []
        for m in e.type.methods {
            guard let ann = m.annotations.first(where: { webSimple($0, e.ctx) == "ExceptionHandler" }) else { continue }
            var exceptions = (ann["value"] ?? ann["exception"])?.classLiterals ?? []
            if exceptions.isEmpty, let first = m.parameters.first { exceptions = [builder.resolve(first.type, e.ctx, enclosing: q).simpleName] }
            let scope: SpringExceptionHandlerRef.Scope = selector.hasAnnotationSelector ? .adviceMaybe(q) : .advice(q)
            refs.append(SpringExceptionHandlerRef(method: m.name, owner: q, exceptions: exceptions, scope: scope, location: location(e.ctx, m.nameRange)))
        }
        return (refs, selector, touched.urls)
    }

    struct AdviceSelector: Sendable, Hashable {
        var packages: [String] = []
        var packageClasses: [String] = []
        var assignable: [String] = []
        var hasAnnotationSelector = false

        enum Admission { case yes, maybe, no }

        func admits(controller: String) -> Admission {
            let package = controller.split(separator: ".").dropLast().joined(separator: ".")
            let simple = controller.split(separator: ".").last.map(String.init) ?? controller
            if packages.isEmpty && packageClasses.isEmpty && assignable.isEmpty { return .yes }
            if packages.contains(where: { package == $0 || package.hasPrefix($0 + ".") }) { return .yes }
            if assignable.contains(where: { $0 == simple || $0 == controller }) { return .yes }
            // `basePackageClasses` names a package by one of its classes; resolving it here would need the literal's imports.
            return packageClasses.isEmpty ? .no : .maybe
        }
    }
}
