import Foundation

/// The method (or constructor) call whose argument list contains the caret, with its candidate
/// overloads and the index of the argument being typed.
struct JavaCallSite {
    let name: String
    let candidates: [JavaMethodStub]
    let argumentIndex: Int
    let isConstructor: Bool
}

/// Everything expected-type inference and call-site resolution need about one completion request.
struct JavaSemanticRequest {
    let source: String
    let bytes: [UInt8]
    let tree: JavaSyntaxTree
    let locals: [JavaLocalVariable]
    let context: JavaResolutionContext
    let index: JavaIndex
}

/// Infers what type the expression being completed should have -- IntelliJ's "expected type",
/// which lifts matching suggestions to the top: the declared type on the left of `=`, the
/// enclosing method's return type after `return`, the parameter type of the argument being
/// typed, `boolean` inside an `if`/`while` condition.
enum JavaExpectedType {
    static func infer(at prefixStart: Int, request: JavaSemanticRequest) async -> [JavaTypeRef] {
        let bytes = request.bytes
        let before = JavaCompletionContextClassifier.skipWhitespace(backwardFrom: prefixStart, in: bytes)
        guard before > 0 else { return [] }
        let previous = bytes[before - 1]

        if previous == UInt8(ascii: "="), before >= 2, !"=!<>+-*/&|^%".utf8.contains(bytes[before - 2]) {
            return await assignmentTarget(endingBefore: before - 1, request: request).map { [$0] } ?? []
        }
        if JavaCompletionContextClassifier.word(endingAt: before, in: bytes) == "return" {
            return await enclosingReturnType(at: prefixStart, request: request).map { [$0] } ?? []
        }
        if previous == UInt8(ascii: "(") || previous == UInt8(ascii: ",") {
            if let keyword = keywordBeforeParenthesis(at: before - 1, bytes: bytes), previous == UInt8(ascii: "(") {
                return ["if", "while"].contains(keyword) ? [.primitive(.boolean)] : []
            }
            guard let site = await callSite(at: prefixStart, request: request) else { return [] }
            var types: [JavaTypeRef] = []
            for method in site.candidates {
                guard let type = parameterType(of: method, at: site.argumentIndex) else { continue }
                if !types.contains(type) { types.append(type) }
            }
            var resolved: [JavaTypeRef] = []
            for type in types {
                resolved.append(await JavaTypeResolver.resolve(type, context: request.context, index: request.index))
            }
            return resolved
        }
        return []
    }

    static func parameterType(of method: JavaMethodStub, at position: Int) -> JavaTypeRef? {
        if position < method.parameters.count {
            let type = method.parameters[position].type
            if position == method.parameters.count - 1, method.modifiers.contains(.varargs), case .array(let element) = type {
                return element
            }
            return type
        }
        if method.modifiers.contains(.varargs), case .array(let element)? = method.parameters.last?.type {
            return element
        }
        return nil
    }

    // MARK: - Assignment

    private static let declarationModifiers: Set<String> = [
        "public", "private", "protected", "static", "final", "transient", "volatile"
    ]

    /// The type of the left-hand side of `lhs = |`: a declaration's declared type (`List<String> x`)
    /// or an assigned variable/field's type (`this.name`, `x`).
    private static func assignmentTarget(endingBefore end: Int, request: JavaSemanticRequest) async -> JavaTypeRef? {
        let bytes = request.bytes
        var start = end
        var depth = 0
        while start > 0 {
            let byte = bytes[start - 1]
            if byte == UInt8(ascii: ")") || byte == UInt8(ascii: "]") || byte == UInt8(ascii: ">") {
                depth += 1
            } else if byte == UInt8(ascii: "(") || byte == UInt8(ascii: "[") || byte == UInt8(ascii: "<") {
                if depth == 0 { break }
                depth -= 1
            } else if depth == 0, byte == UInt8(ascii: ";") || byte == UInt8(ascii: "{") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: ",") {
                break
            }
            start -= 1
        }
        var lhs = String(decoding: bytes[start..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop annotations and modifiers of a field declaration.
        var words = lhs.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        while let first = words.first, declarationModifiers.contains(first) || first.hasPrefix("@") {
            words.removeFirst()
        }
        lhs = words.joined(separator: " ")
        guard !lhs.isEmpty else { return nil }

        guard let synthetic = JavaSyntaxParser().parse("class __S__ { void __m__() { \(lhs); } }") else { return nil }
        let block = synthetic.rootNode.namedChildren.first?.child(byFieldName: "body")?
            .namedChildren.first { $0.type == "method_declaration" }?.child(byFieldName: "body")
        if let declaration = block?.namedChildren.first(where: { $0.type == "local_variable_declaration" }),
           let typeNode = declaration.child(byFieldName: "type") {
            guard typeNode.text != "var" else { return nil }
            return await JavaTypeResolver.resolve(JavaTypeNodeConverter.convert(typeNode), context: request.context, index: request.index)
        }
        let info = await JavaExpressionTyper.typeOfExpression(lhs, locals: request.locals, context: request.context, index: request.index)
        guard let info, !info.isTypeReference else { return nil }
        return info.type
    }

    // MARK: - Return

    private static func enclosingReturnType(at offset: Int, request: JavaSemanticRequest) async -> JavaTypeRef? {
        var current: SyntaxNode? = request.tree.node(atByteOffset: offset)
        while let node = current {
            if node.type == "lambda_expression" { return nil }
            if node.type == "method_declaration", let typeNode = node.child(byFieldName: "type") {
                guard typeNode.type != "void_type" else { return nil }
                return await JavaTypeResolver.resolve(JavaTypeNodeConverter.convert(typeNode), context: request.context, index: request.index)
            }
            current = node.parent
        }
        return nil
    }

    // MARK: - Call sites

    /// The call whose argument list the caret is in: its name, overloads, and argument index.
    static func callSite(at offset: Int, request: JavaSemanticRequest) async -> JavaCallSite? {
        let bytes = request.bytes
        guard let openParen = unbalancedOpenParenthesis(before: offset, bytes: bytes) else { return nil }
        let argumentIndex = topLevelCommaCount(from: openParen + 1, to: offset, bytes: bytes)
        let nameEnd = JavaCompletionContextClassifier.skipWhitespace(backwardFrom: openParen, in: bytes)
        var nameStart = nameEnd
        while nameStart > 0, JavaCompletionContextClassifier.isIdentifierByte(bytes[nameStart - 1]) {
            nameStart -= 1
        }
        // `new Foo<Bar>(` / `new Foo(`: skip a diamond or type arguments.
        var typeEnd = nameEnd
        if nameStart == nameEnd, nameEnd > 0, bytes[nameEnd - 1] == UInt8(ascii: ">") {
            var depth = 0
            var cursor = nameEnd
            while cursor > 0 {
                cursor -= 1
                if bytes[cursor] == UInt8(ascii: ">") { depth += 1 }
                if bytes[cursor] == UInt8(ascii: "<") {
                    depth -= 1
                    if depth == 0 { break }
                }
            }
            typeEnd = JavaCompletionContextClassifier.skipWhitespace(backwardFrom: cursor, in: bytes)
            nameStart = typeEnd
            while nameStart > 0, JavaCompletionContextClassifier.isIdentifierByte(bytes[nameStart - 1]) || bytes[nameStart - 1] == UInt8(ascii: ".") {
                nameStart -= 1
            }
        }
        guard nameStart < typeEnd else { return nil }
        let name = String(decoding: bytes[nameStart..<typeEnd], as: UTF8.self)
        if ["if", "while", "for", "switch", "catch", "synchronized", "return"].contains(name) {
            return nil
        }

        // Constructor call?
        var constructorStart = nameStart
        while constructorStart > 0, JavaCompletionContextClassifier.isIdentifierByte(bytes[constructorStart - 1]) || bytes[constructorStart - 1] == UInt8(ascii: ".") {
            constructorStart -= 1
        }
        let beforeType = JavaCompletionContextClassifier.skipWhitespace(backwardFrom: constructorStart, in: bytes)
        if JavaCompletionContextClassifier.word(endingAt: beforeType, in: bytes) == "new" {
            let typeText = String(decoding: bytes[constructorStart..<typeEnd], as: UTF8.self)
            let type = await JavaTypeResolver.resolve(
                typeText.contains(".") ? dottedType(typeText) : .unresolved(simpleName: typeText, arguments: []),
                context: request.context, index: request.index
            )
            let constructors = await JavaMemberLookup.constructors(of: type, context: request.context, index: request.index)
            return JavaCallSite(name: type.simpleDisplayName, candidates: constructors, argumentIndex: argumentIndex, isConstructor: true)
        }

        let simpleName = String(name.split(separator: ".").last ?? Substring(name))
        var candidates: [JavaMethodStub] = []
        if nameStart > 0, bytes[nameStart - 1] == UInt8(ascii: ".") {
            guard let receiver = await JavaExpressionTyper.receiverInfo(
                source: request.source, realTree: request.tree, dotOffset: nameStart - 1, context: request.context, index: request.index
            ), receiver.packageName == nil else { return nil }
            let mode: JavaMemberLookupMode = receiver.isTypeReference ? .staticOnly : .instance
            candidates = await JavaExpressionTyper.methods(named: simpleName, on: receiver.type, mode: mode, context: request.context, index: request.index)
        } else if simpleName == "this" || simpleName == "super" {
            var owner: JavaTypeRef?
            if let enclosing = request.context.enclosingTypeQualifiedNames.first {
                owner = simpleName == "this"
                    ? .classType(qualifiedName: enclosing, arguments: [], outer: nil)
                    : await JavaMemberLookup.directSuperclass(of: enclosing, context: request.context, index: request.index)
            }
            if let owner {
                candidates = await JavaMemberLookup.constructors(of: owner, context: request.context, index: request.index)
            }
        } else {
            for enclosing in request.context.enclosingTypeQualifiedNames where candidates.isEmpty {
                let selfType = JavaTypeRef.classType(qualifiedName: enclosing, arguments: [], outer: nil)
                candidates = await JavaExpressionTyper.methods(named: simpleName, on: selfType, mode: .instance, context: request.context, index: request.index)
            }
            if candidates.isEmpty {
                candidates = await JavaStaticImports.members(context: request.context, index: request.index).compactMap {
                    guard case .method(let method, _) = $0, method.name == simpleName else { return nil }
                    return method
                }
            }
        }
        guard !candidates.isEmpty else { return nil }
        return JavaCallSite(name: simpleName, candidates: candidates, argumentIndex: argumentIndex, isConstructor: false)
    }

    private static func dottedType(_ text: String) -> JavaTypeRef {
        .classType(qualifiedName: text, arguments: [], outer: nil)
    }

    private static func keywordBeforeParenthesis(at openParen: Int, bytes: [UInt8]) -> String? {
        let end = JavaCompletionContextClassifier.skipWhitespace(backwardFrom: openParen, in: bytes)
        guard let word = JavaCompletionContextClassifier.word(endingAt: end, in: bytes),
              ["if", "while", "for", "switch", "catch", "synchronized"].contains(word) else { return nil }
        return word
    }

    /// The nearest `(` before `offset` that isn't closed before it, skipping string literals;
    /// stops at statement boundaries.
    static func unbalancedOpenParenthesis(before offset: Int, bytes: [UInt8]) -> Int? {
        var depth = 0
        var cursor = min(offset, bytes.count)
        var scanned = 0
        while cursor > 0, scanned < 4000 {
            cursor -= 1
            scanned += 1
            switch bytes[cursor] {
            case UInt8(ascii: "\""):
                // Skip back over a string literal.
                while cursor > 0 {
                    cursor -= 1
                    if bytes[cursor] == UInt8(ascii: "\""), cursor == 0 || bytes[cursor - 1] != UInt8(ascii: "\\") { break }
                }
            case UInt8(ascii: ")"), UInt8(ascii: "]"):
                depth += 1
            case UInt8(ascii: "("), UInt8(ascii: "["):
                if depth == 0 {
                    return bytes[cursor] == UInt8(ascii: "(") ? cursor : nil
                }
                depth -= 1
            case UInt8(ascii: ";"), UInt8(ascii: "{"), UInt8(ascii: "}"):
                if depth == 0 { return nil }
            default:
                break
            }
        }
        return nil
    }

    static func topLevelCommaCount(from start: Int, to end: Int, bytes: [UInt8]) -> Int {
        var depth = 0
        var count = 0
        var cursor = start
        var inString = false
        while cursor < min(end, bytes.count) {
            let byte = bytes[cursor]
            if inString {
                if byte == UInt8(ascii: "\\") { cursor += 1 } else if byte == UInt8(ascii: "\"") { inString = false }
            } else {
                switch byte {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"), UInt8(ascii: "<"): depth += 1
                case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"), UInt8(ascii: ">"): depth = max(0, depth - 1)
                case UInt8(ascii: ","): if depth == 0 { count += 1 }
                default: break
                }
            }
            cursor += 1
        }
        return count
    }
}

/// Type compatibility for expected-type ranking, with per-request caching of supertype sets.
actor JavaAssignability {
    private let index: JavaIndex
    private let context: JavaResolutionContext
    private var closures: [String: Set<String>] = [:]

    init(index: JavaIndex, context: JavaResolutionContext) {
        self.index = index
        self.context = context
    }

    /// Source-declared types arrive as `.unresolved(simpleName)`; resolve them at the call site.
    func resolve(_ type: JavaTypeRef) async -> JavaTypeRef {
        await JavaTypeResolver.resolve(type, context: context, index: index)
    }

    /// Whether a value of `type` can be used where `expected` is wanted (erased; boxing and
    /// primitive widening included).
    func isAssignable(_ type: JavaTypeRef, to expected: JavaTypeRef) async -> Bool {
        switch (type, expected) {
        case (.primitive(let from), .primitive(let to)):
            return from == to || Self.widens(from, to)
        case (.primitive, .classType(let name, _, _)):
            return JavaExpressionTyper.boxed(type).erasedQualifiedName == name || name == "java.lang.Object"
        case (.classType(let name, _, _), .primitive(let to)):
            return JavaExpressionTyper.boxed(.primitive(to)).erasedQualifiedName == name
        case (.classType(let name, _, _), .classType(let expectedName, _, _)):
            if name == expectedName || expectedName == "java.lang.Object" { return true }
            return await closure(of: name).contains(expectedName)
        case (.array(let element), .array(let expectedElement)):
            return await isAssignable(element, to: expectedElement)
        case (.array, .classType(let expectedName, _, _)):
            return expectedName == "java.lang.Object"
        default:
            return false
        }
    }

    private func closure(of name: String) async -> Set<String> {
        if let cached = closures[name] { return cached }
        let computed = await JavaMemberLookup.supertypeClosure(of: name, index: index)
        closures[name] = computed
        return computed
    }

    private static func widens(_ from: JavaPrimitive, _ to: JavaPrimitive) -> Bool {
        let order: [JavaPrimitive] = [.byte, .short, .int, .long, .float, .double]
        if from == .char { return [.int, .long, .float, .double].contains(to) }
        guard let f = order.firstIndex(of: from), let t = order.firstIndex(of: to) else { return false }
        return f < t
    }
}
