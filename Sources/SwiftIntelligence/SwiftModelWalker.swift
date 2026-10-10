import EditorIntelligence
import Foundation
import LanguageSyntax

/// One pass over a Swift tree. It is iterative, with an explicit stack and a depth cap: indexing
/// runs on a cooperative-pool thread whose stack is about 512 KB, and a few hundred recursive
/// calls of a function with a large frame write into the guard page (TypeScript's walk had to be
/// rewritten for this).
public final class SwiftModelWalker {
    private struct Frame {
        /// The type or extension whose body this node sits directly in, so declarations become its members.
        var container: Builder?
        /// End of the enclosing block, where a local `let` stops being visible.
        var blockEnd: Int
        /// Inside a function, closure or accessor body: declarations are local bindings.
        var isLocal: Bool
        /// Set when the node is the callee of a call: the labels of that call's arguments.
        var calleeLabels: [String]?
        var depth: Int

        var isCallee: Bool { calleeLabels != nil }
    }

    private final class Builder {
        var declaration: SwiftFileModel.Declaration
        let parent: Builder?
        /// A type declared inside a function body: walked for uses, never listed.
        let isDetached: Bool

        init(_ declaration: SwiftFileModel.Declaration, parent: Builder?, isDetached: Bool) {
            self.declaration = declaration
            self.parent = parent
            self.isDetached = isDetached
        }
    }

    private enum Work {
        case visit(SyntaxNode, Frame)
        case finish(Builder)
    }

    private static let maxDepth = 400
    private static let maxChainLength = 64

    private let tree: LanguageSyntax.SyntaxTree
    private let text: SourceTextMap
    private var model = SwiftFileModel()
    private var stack: [Work] = []
    /// Doc comments by the start byte of the declaration they precede.
    private var docs: [Int: String] = [:]

    private static let typeNodeTypes: Set<String> = [
        "user_type", "optional_type", "array_type", "dictionary_type", "tuple_type", "function_type",
        "opaque_type", "existential_type", "protocol_composition_type", "metatype", "type_identifier"
    ]
    /// The anonymous token that introduces a type declaration. `class` is also a modifier of a
    /// member (`class func`), so the sets are kept apart.
    private static let typeKeywords: Set<String> = ["class", "struct", "enum", "actor", "extension", "protocol"]
    private static let memberKeywords: Set<String> = [
        "func", "var", "let", "init", "deinit", "subscript", "typealias", "associatedtype", "case"
    ]

    public init(tree: LanguageSyntax.SyntaxTree, text: SourceTextMap) {
        self.tree = tree
        self.text = text
    }

    public func build() -> SwiftFileModel {
        let root = tree.rootNode
        model.identifiers = Self.identifierTokens(in: text.utf8)
        collectErrors(root)
        let frame = Frame(container: nil, blockEnd: text.utf8.count, isLocal: false, calleeLabels: nil, depth: 0)
        pushChildren(of: root, frame: frame)
        while let work = stack.popLast() {
            switch work {
            case .finish(let builder):
                if builder.isDetached { continue }
                if let parent = builder.parent {
                    parent.declaration.members.append(builder.declaration)
                } else {
                    model.declarations.append(builder.declaration)
                }
            case .visit(let node, let frame):
                visit(node, frame)
            }
        }
        model.uses.sort { $0.bytes.lowerBound < $1.bytes.lowerBound }
        return model
    }

    // MARK: Errors

    private func collectErrors(_ root: SyntaxNode) {
        guard root.hasError else { return }
        var pending = [root]
        while let node = pending.popLast() {
            if node.type == "ERROR" {
                model.errors.append(SwiftFileModel.SyntaxProblem(bytes: node.byteRange, isMissing: false, expected: nil))
                continue
            }
            if node.isMissing {
                model.errors.append(SwiftFileModel.SyntaxProblem(bytes: node.byteRange, isMissing: true, expected: node.type))
                continue
            }
            node.enumerateChildren { child, _ in
                if child.hasError || child.isMissing { pending.append(child) }
            }
        }
        model.errors.sort { $0.bytes.lowerBound < $1.bytes.lowerBound }
    }

    /// Every identifier-shaped token, found by a byte scan (comments and strings included: this
    /// only picks the files that can mention a name, and a parse verifies each).
    private static func identifierTokens(in bytes: [UInt8]) -> Set<String> {
        var result = Set<String>()
        var start = -1
        for index in 0...bytes.count {
            let byte = index < bytes.count ? bytes[index] : 0x20
            let isIdentifierByte = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte >= 0x80
            if isIdentifierByte {
                if start < 0 { start = index }
            } else if start >= 0 {
                if index - start >= 2, !(bytes[start] >= 0x30 && bytes[start] <= 0x39) {
                    result.insert(String(decoding: bytes[start..<index], as: UTF8.self))
                }
                start = -1
            }
        }
        return result
    }

    // MARK: Traversal

    private func pushChildren(of node: SyntaxNode, frame: Frame, onlyFields: Set<String>? = nil, skipFields: Set<String> = []) {
        guard frame.depth < Self.maxDepth else { return }
        var children: [(node: SyntaxNode, field: String?)] = []
        node.enumerateChildren { child, field in
            children.append((child, field))
        }
        var comments: [SyntaxNode] = []
        var next = frame
        next.depth += 1
        next.calleeLabels = nil
        var work: [Work] = []
        for (index, entry) in children.enumerated() {
            let child = entry.node
            if child.type == "comment" || child.type == "multiline_comment" {
                if let last = comments.last, !isAdjacent(last.endByte, child.startByte) { comments.removeAll() }
                comments.append(child)
                continue
            }
            guard child.isNamed else { continue }
            if let only = onlyFields {
                guard let field = entry.field, only.contains(field) else { continue }
            }
            if let field = entry.field, skipFields.contains(field) { continue }
            if !comments.isEmpty {
                if isAdjacent(comments.last?.endByte ?? 0, child.startByte), let doc = docComment(from: comments) {
                    docs[child.startByte] = doc
                }
                comments.removeAll()
            }
            var childFrame = next
            if child.type == "statements" {
                if index + 1 < children.count, children[index + 1].node.type == "}" {
                    childFrame.blockEnd = children[index + 1].node.endByte
                } else {
                    childFrame.blockEnd = max(child.endByte, node.endByte)
                }
                childFrame.isLocal = true
            }
            work.append(.visit(child, childFrame))
        }
        for item in work.reversed() { stack.append(item) }
    }

    private func push(_ node: SyntaxNode, _ frame: Frame, calleeLabels: [String]? = nil) {
        guard frame.depth < Self.maxDepth else { return }
        var next = frame
        next.depth += 1
        next.calleeLabels = calleeLabels
        stack.append(.visit(node, next))
    }

    private func visit(_ node: SyntaxNode, _ frame: Frame) {
        switch node.type {
        case "class_declaration", "protocol_declaration":
            visitType(node, frame)
        case "function_declaration", "protocol_function_declaration", "init_declaration", "deinit_declaration",
             "subscript_declaration":
            visitFunction(node, frame)
        case "property_declaration", "protocol_property_declaration":
            visitProperty(node, frame)
        case "enum_entry":
            visitEnumEntry(node, frame)
        case "typealias_declaration":
            visitTypeAlias(node, frame)
        case "associatedtype_declaration":
            visitAssociatedType(node, frame)
        case "import_declaration":
            visitImport(node)
        case "lambda_literal":
            visitLambda(node, frame)
        case "if_statement", "while_statement":
            visitConditional(node, frame, bindsToEnd: false)
        case "guard_statement":
            visitConditional(node, frame, bindsToEnd: true)
        case "for_statement":
            visitFor(node, frame)
        case "catch_block":
            visitCatch(node, frame)
        case "switch_entry":
            visitSwitchEntry(node, frame)
        case "computed_property":
            var inner = frame
            inner.isLocal = true
            pushChildren(of: node, frame: inner)
        case "computed_setter":
            addImplicitBinding("newValue", at: node, scopeEnd: node.endByte)
            var inner = frame
            inner.isLocal = true
            pushChildren(of: node, frame: inner)
        case "navigation_expression":
            visitNavigation(node, frame)
        case "call_expression":
            visitCall(node, frame)
        case "constructor_expression":
            visitConstructor(node, frame)
        case "prefix_expression":
            visitPrefix(node, frame)
        case "value_argument":
            pushChildren(of: node, frame: frame, onlyFields: ["value", "reference_specifier"])
        case "simple_identifier":
            recordUse(node, role: .value, calleeLabels: frame.calleeLabels)
        case "type_identifier":
            recordUse(node, role: .type, calleeLabels: nil)
        case "self_expression", "super_expression", "comment", "multiline_comment", "line_str_text",
             "multi_line_str_text", "directive", "integer_literal", "real_literal", "boolean_literal":
            break
        default:
            pushChildren(of: node, frame: frame)
        }
    }

    // MARK: Declarations

    private struct Header {
        var children: [(node: SyntaxNode, field: String?)]
        var keyword: SyntaxNode?
        var modifiers: SyntaxNode?
    }

    private func header(of node: SyntaxNode) -> Header {
        var header = Header(children: [], keyword: nil, modifiers: nil)
        let keywords = node.type == "class_declaration" || node.type == "protocol_declaration"
            ? Self.typeKeywords : Self.memberKeywords
        node.enumerateChildren { child, field in
            header.children.append((child, field))
            if header.keyword == nil, !child.isNamed, keywords.contains(child.type) {
                header.keyword = child
            }
            if child.type == "modifiers", header.modifiers == nil { header.modifiers = child }
        }
        return header
    }

    private struct ParsedModifiers {
        var access: SwiftFileModel.Access = .internal
        var isStatic = false
        var isOverride = false
        var attributes: [String] = []
    }

    private func parseModifiers(_ node: SyntaxNode, header: Header) -> ParsedModifiers {
        var result = ParsedModifiers()
        var blanked = Array(text.utf8[node.startByte..<min(node.endByte, text.utf8.count)])
        if let modifiers = header.modifiers {
            for attribute in modifiers.namedChildren where attribute.type == "attribute" {
                if let name = attribute.namedChildren.first, name.type == "user_type" {
                    if let simple = typeName(of: name) { result.attributes.append(simple) }
                }
                let lower = max(0, attribute.startByte - node.startByte)
                let upper = min(attribute.endByte - node.startByte, blanked.count)
                if lower < upper {
                    for index in lower..<upper { blanked[index] = 0x20 }
                }
            }
        }
        let limit = header.keyword.map { $0.startByte - node.startByte } ?? blanked.count
        let prefix = blanked[0..<max(0, min(limit, blanked.count))]
        var word = [UInt8]()
        var words: [(String, Bool)] = []
        func flush(followedByParenthesis: Bool) {
            if !word.isEmpty { words.append((String(decoding: word, as: UTF8.self), followedByParenthesis)) }
            word.removeAll(keepingCapacity: true)
        }
        for byte in prefix {
            let isLetter = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
            if isLetter {
                word.append(byte)
            } else {
                flush(followedByParenthesis: byte == 0x28)
            }
        }
        flush(followedByParenthesis: false)
        for (word, isRestriction) in words {
            switch word {
            case "private" where !isRestriction: result.access = .private
            case "fileprivate" where !isRestriction: result.access = .fileprivate
            case "internal" where !isRestriction: result.access = .internal
            case "public" where !isRestriction: result.access = .public
            case "open" where !isRestriction: result.access = .open
            case "static", "class": result.isStatic = true
            case "override": result.isOverride = true
            default: break
            }
        }
        return result
    }

    /// The text of `node` from its start up to its body, whitespace collapsed.
    private func signature(of node: SyntaxNode, endingAt end: Int) -> String {
        let upper = min(max(end, node.startByte), text.utf8.count)
        let raw = String(decoding: text.utf8[node.startByte..<upper], as: UTF8.self)
        var result = ""
        var lastWasSpace = false
        for character in raw {
            if character.isWhitespace {
                if !lastWasSpace, !result.isEmpty { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
            if result.count >= 300 { break }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func docComment(from comments: [SyntaxNode]) -> String? {
        var lines: [String] = []
        for comment in comments {
            let raw = comment.text
            if raw.hasPrefix("///") {
                lines.append(String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            } else if raw.hasPrefix("/**") {
                var body = String(raw.dropFirst(3))
                if body.hasSuffix("*/") { body = String(body.dropLast(2)) }
                for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                    var trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("*") { trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) }
                    lines.append(trimmed)
                }
            } else {
                lines.removeAll()
            }
        }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Only whitespace with at most one line break lies between the two offsets.
    private func isAdjacent(_ end: Int, _ start: Int) -> Bool {
        guard end <= start, start <= text.utf8.count else { return false }
        var breaks = 0
        for byte in text.utf8[end..<start] {
            if byte == 0x0A { breaks += 1 }
            else if byte != 0x20 && byte != 0x09 && byte != 0x0D { return false }
        }
        return breaks <= 1
    }

    private func makeDeclaration(
        name: String, kind: SwiftFileModel.Kind, node: SyntaxNode, nameBytes: Range<Int>,
        header: Header, frame: Frame, bodyEnd: SyntaxNode?
    ) -> SwiftFileModel.Declaration {
        let modifiers = parseModifiers(node, header: header)
        let body = bodyEnd.map { $0.startByte..<$0.endByte } ?? node.endByte..<node.endByte
        let signatureEnd = bodyEnd?.startByte ?? node.endByte
        return SwiftFileModel.Declaration(
            name: name, kind: kind, nameBytes: nameBytes, fullBytes: node.byteRange, bodyBytes: body,
            access: modifiers.access, isStatic: modifiers.isStatic, isOverride: modifiers.isOverride,
            inherits: [], typeName: nil, typeText: nil, parameters: [], generics: [],
            attributes: modifiers.attributes, signature: signature(of: node, endingAt: signatureEnd),
            docComment: docs[node.startByte], members: [], isTopLevel: frame.container == nil && !frame.isLocal,
            valueChain: nil
        )
    }

    /// `name`'s declaration goes into the enclosing type or the file; a local one is only a binding.
    private func attach(_ declaration: SwiftFileModel.Declaration, frame: Frame) {
        if let container = frame.container {
            container.declaration.members.append(declaration)
        } else if !frame.isLocal {
            model.declarations.append(declaration)
        }
    }

    private func visitType(_ node: SyntaxNode, _ frame: Frame) {
        let header = header(of: node)
        var kind: SwiftFileModel.Kind = node.type == "protocol_declaration" ? .protocol : .class
        if let keyword = header.keyword {
            switch keyword.type {
            case "struct": kind = .struct
            case "enum": kind = .enum
            case "actor": kind = .actor
            case "extension": kind = .extension
            case "protocol": kind = .protocol
            default: kind = .class
            }
        }
        var nameNode: SyntaxNode?
        var bodyNode: SyntaxNode?
        var inherits: [String] = []
        var generics: [SyntaxNode] = []
        for (child, field) in header.children {
            if field == "name", nameNode == nil, child.type == "type_identifier" || child.type == "user_type" {
                nameNode = child
            } else if field == "body" {
                bodyNode = child
            } else if child.type == "inheritance_specifier" {
                if let target = child.child(byFieldName: "inherits_from") ?? child.namedChildren.first,
                   let name = typeName(of: target) { inherits.append(name) }
            } else if child.type == "type_parameters" {
                generics.append(child)
            }
        }
        let name = nameNode.flatMap { typeName(of: $0) } ?? ""
        let nameBytes = nameNode?.byteRange ?? node.startByte..<node.startByte
        var declaration = makeDeclaration(
            name: name, kind: kind, node: node, nameBytes: nameBytes, header: header, frame: frame, bodyEnd: bodyNode
        )
        declaration.inherits = inherits
        let genericNames = genericParameterNames(generics)
        declaration.generics = genericNames
        if let bodyNode, bodyNode.byteRange.count >= 2 {
            declaration.bodyBytes = (bodyNode.startByte + 1)..<max(bodyNode.startByte + 1, bodyNode.endByte - 1)
        }
        if frame.isLocal, kind.isNominalType {
            addBinding(
                name: name, nameBytes: nameBytes, scopeStart: node.startByte, scopeEnd: frame.blockEnd,
                symbolKind: .type, typeName: name, signature: declaration.signature
            )
        }
        let builder = Builder(declaration, parent: frame.container, isDetached: frame.isLocal)
        stack.append(.finish(builder))
        for generic in generics { addGenericBindings(generic, scopeEnd: node.endByte, from: node.startByte) }
        var childFrame = frame
        childFrame.depth += 1
        childFrame.calleeLabels = nil
        var work: [Work] = []
        for (child, field) in header.children where child.isNamed {
            if child.byteRange == nameNode?.byteRange { continue }
            var next = childFrame
            if field == "body" {
                next.container = builder
                next.isLocal = false
                next.blockEnd = child.endByte
            }
            work.append(.visit(child, next))
        }
        for item in work.reversed() { stack.append(item) }
    }

    private func genericParameterNames(_ lists: [SyntaxNode]) -> [String] {
        var names: [String] = []
        for list in lists {
            for parameter in list.namedChildren where parameter.type == "type_parameter" {
                if let first = parameter.namedChildren.first(where: { $0.type == "type_identifier" }) {
                    names.append(first.text)
                }
            }
        }
        return names
    }

    private func addGenericBindings(_ list: SyntaxNode, scopeEnd: Int, from start: Int) {
        for parameter in list.namedChildren where parameter.type == "type_parameter" {
            guard let name = parameter.namedChildren.first(where: { $0.type == "type_identifier" }) else { continue }
            addBinding(
                name: name.text, nameBytes: name.byteRange, scopeStart: start, scopeEnd: scopeEnd,
                symbolKind: .type, typeName: nil, signature: nil
            )
        }
    }

    private func visitFunction(_ node: SyntaxNode, _ frame: Frame) {
        let header = header(of: node)
        var kind: SwiftFileModel.Kind = .function
        var name = ""
        var nameBytes = node.startByte..<node.startByte
        switch node.type {
        case "deinit_declaration":
            kind = .deinitializer
            name = "deinit"
            if let keyword = header.keyword { nameBytes = keyword.byteRange }
        case "subscript_declaration":
            kind = .subscript
            name = "subscript"
            if let keyword = header.keyword { nameBytes = keyword.byteRange }
        default:
            if header.keyword?.type == "init" {
                kind = .initializer
                name = "init"
                if let keyword = header.keyword { nameBytes = keyword.byteRange }
            }
        }
        var parameters: [SwiftFileModel.Parameter] = []
        var parameterNodes: [SyntaxNode] = []
        var returnType: SyntaxNode?
        var body: SyntaxNode?
        var generics: [SyntaxNode] = []
        for (child, field) in header.children {
            switch child.type {
            case "parameter":
                parameterNodes.append(child)
                parameters.append(parameter(from: child))
            case "type_parameters":
                generics.append(child)
            default:
                if field == "default_value", !parameters.isEmpty { parameters[parameters.count - 1].hasDefault = true }
                if field == "body" { body = child }
                if field == "return_type" { returnType = child }
                if field == "name" {
                    if kind == .function, name.isEmpty, child.type == "simple_identifier" || child.type == "custom_operator" {
                        name = child.text
                        nameBytes = child.byteRange
                    } else if Self.typeNodeTypes.contains(child.type) {
                        returnType = child
                    }
                }
                if kind == .subscript, child.type == "computed_property" { body = child }
            }
        }
        var declaration = makeDeclaration(
            name: name, kind: kind, node: node, nameBytes: nameBytes, header: header, frame: frame, bodyEnd: body
        )
        declaration.parameters = parameters
        declaration.generics = genericParameterNames(generics)
        if let returnType {
            declaration.typeName = typeName(of: returnType)
            declaration.typeText = returnType.text
        }
        if let body, body.byteRange.count >= 2, body.type == "function_body" {
            declaration.bodyBytes = (body.startByte + 1)..<max(body.startByte + 1, body.endByte - 1)
        }
        if frame.isLocal, kind == .function, !name.isEmpty {
            addBinding(
                name: name, nameBytes: nameBytes, scopeStart: 0, scopeEnd: frame.blockEnd,
                symbolKind: .function, typeName: declaration.typeName, signature: declaration.signature
            )
        } else {
            attach(declaration, frame: frame)
        }
        if let body {
            for (index, parameterNode) in parameterNodes.enumerated() where index < parameters.count {
                guard let internalName = internalNameNode(of: parameterNode) else { continue }
                addBinding(
                    name: internalName.text, nameBytes: internalName.byteRange,
                    scopeStart: body.startByte, scopeEnd: body.endByte, symbolKind: .parameter,
                    typeName: parameters[index].typeName, typeText: parameters[index].typeText
                )
            }
        }
        for generic in generics {
            addGenericBindings(generic, scopeEnd: node.endByte, from: node.startByte)
        }
        var inner = frame
        inner.depth += 1
        inner.calleeLabels = nil
        var work: [Work] = []
        for (child, field) in header.children where child.isNamed {
            if field == "name", child.type == "simple_identifier" || child.type == "custom_operator" { continue }
            var next = inner
            if field == "body" || child.type == "computed_property" {
                next.isLocal = true
                next.container = nil
                next.blockEnd = child.endByte
            }
            if child.type == "parameter" {
                work.append(contentsOf: typeUseWork(in: child, frame: next))
                continue
            }
            work.append(.visit(child, next))
        }
        for item in work.reversed() { stack.append(item) }
    }

    /// The type positions of a parameter (`x: Foo`), without its names.
    private func typeUseWork(in parameter: SyntaxNode, frame: Frame) -> [Work] {
        var work: [Work] = []
        parameter.enumerateChildren { child, field in
            guard child.isNamed else { return }
            if field == "name", child.type == "simple_identifier" { return }
            if field == "external_name" { return }
            work.append(.visit(child, frame))
        }
        return work
    }

    private func parameter(from node: SyntaxNode) -> SwiftFileModel.Parameter {
        var external: String?
        var internalName: String?
        var typeNode: SyntaxNode?
        var isVariadic = false
        node.enumerateChildren { child, field in
            if field == "external_name" {
                external = child.text
            } else if field == "name" {
                if child.type == "simple_identifier", internalName == nil {
                    internalName = child.text
                } else {
                    typeNode = child
                }
            } else if !child.isNamed, child.type == "..." {
                isVariadic = true
            }
        }
        let name = internalName ?? external ?? ""
        let label: String?
        if let external {
            label = external == "_" ? nil : external
        } else {
            label = name.isEmpty ? nil : name
        }
        return SwiftFileModel.Parameter(
            label: label, name: name, typeName: typeNode.flatMap { typeName(of: $0) },
            typeText: typeNode?.text, hasDefault: false, isVariadic: isVariadic
        )
    }

    private func internalNameNode(of parameter: SyntaxNode) -> SyntaxNode? {
        var found: SyntaxNode?
        parameter.enumerateChildren { child, field in
            if found == nil, field == "name", child.type == "simple_identifier" { found = child }
        }
        return found
    }

    private func visitProperty(_ node: SyntaxNode, _ frame: Frame) {
        let header = header(of: node)
        var patternNodes: [SyntaxNode] = []
        var annotation: SyntaxNode?
        var valueNode: SyntaxNode?
        var isConstant = false
        var computed: SyntaxNode?
        for (child, field) in header.children {
            switch child.type {
            case "pattern" where field == "name":
                patternNodes.append(child)
            case "type_annotation":
                annotation = child.child(byFieldName: "name") ?? child.namedChildren.first
            case "value_binding_pattern":
                isConstant = child.text.contains("let")
            default:
                if field == "value" { valueNode = child }
                if field == "computed_value" { computed = child }
            }
        }
        let names = patternNodes.flatMap { patternIdentifiers($0) }
        let writtenType = annotation.flatMap { typeName(of: $0) }
        let writtenText = annotation?.text
        let chain = (annotation == nil && names.count == 1) ? valueNode.map { makeChain($0) } : nil
        let isMember = !frame.isLocal
        for name in names {
            if isMember {
                var declaration = makeDeclaration(
                    name: name.text, kind: .property, node: node, nameBytes: name.byteRange,
                    header: header, frame: frame, bodyEnd: computed
                )
                declaration.typeName = writtenType
                declaration.typeText = writtenText
                declaration.valueChain = chain
                declaration.isConstant = isConstant
                declaration.hasInitializer = valueNode != nil
                declaration.isComputed = computed != nil
                if let computed, computed.byteRange.count >= 2 {
                    declaration.bodyBytes = (computed.startByte + 1)..<max(computed.startByte + 1, computed.endByte - 1)
                }
                attach(declaration, frame: frame)
            } else {
                addBinding(
                    name: name.text, nameBytes: name.byteRange, scopeStart: node.endByte, scopeEnd: frame.blockEnd,
                    symbolKind: .local, typeName: writtenType, typeText: writtenText, source: chain,
                    isConstant: isConstant, signature: signature(of: node, endingAt: valueNode?.startByte ?? node.endByte)
                )
            }
        }
        var inner = frame
        inner.depth += 1
        inner.calleeLabels = nil
        var work: [Work] = []
        for (child, field) in header.children where child.isNamed {
            if field == "name", child.type == "pattern" { continue }
            if child.type == "value_binding_pattern" { continue }
            var next = inner
            if field == "computed_value" { next.isLocal = true; next.container = nil; next.blockEnd = child.endByte }
            work.append(.visit(child, next))
        }
        for item in work.reversed() { stack.append(item) }
    }

    private func visitEnumEntry(_ node: SyntaxNode, _ frame: Frame) {
        let header = header(of: node)
        var names: [SyntaxNode] = []
        var parameters: [SwiftFileModel.Parameter] = []
        for (child, field) in header.children {
            if field == "name", child.type == "simple_identifier" {
                names.append(child)
            } else if child.type == "enum_type_parameters" {
                var label: String?
                child.enumerateChildren { item, itemField in
                    if item.type == "simple_identifier", itemField != "name" {
                        label = item.text
                    } else if itemField == "name", Self.typeNodeTypes.contains(item.type) {
                        parameters.append(SwiftFileModel.Parameter(
                            label: label, name: label ?? "", typeName: typeName(of: item), typeText: item.text,
                            hasDefault: false, isVariadic: false
                        ))
                        label = nil
                    }
                }
            }
        }
        for name in names where !frame.isLocal {
            var declaration = makeDeclaration(
                name: name.text, kind: .enumCase, node: node, nameBytes: name.byteRange,
                header: header, frame: frame, bodyEnd: nil
            )
            declaration.parameters = parameters
            declaration.signature = "case " + name.text + (parameters.isEmpty ? "" : "(" + parameters.map { $0.typeText ?? "" }.joined(separator: ", ") + ")")
            attach(declaration, frame: frame)
        }
        for (child, field) in header.children.reversed() where child.isNamed && field != "name" {
            if child.type == "enum_type_parameters" {
                child.enumerateChildren { item, itemField in
                    if itemField == "name", item.isNamed, Self.typeNodeTypes.contains(item.type) {
                        push(item, frame)
                    }
                }
            }
        }
    }

    private func visitTypeAlias(_ node: SyntaxNode, _ frame: Frame) {
        let header = header(of: node)
        var nameNode: SyntaxNode?
        var target: SyntaxNode?
        for (child, field) in header.children where field == "name" {
            if nameNode == nil, child.type == "type_identifier" { nameNode = child } else { target = child }
        }
        guard let nameNode else { return }
        var declaration = makeDeclaration(
            name: nameNode.text, kind: .typeAlias, node: node, nameBytes: nameNode.byteRange,
            header: header, frame: frame, bodyEnd: nil
        )
        declaration.typeName = target.flatMap { typeName(of: $0) }
        declaration.typeText = target?.text
        if frame.isLocal {
            addBinding(
                name: nameNode.text, nameBytes: nameNode.byteRange, scopeStart: node.startByte, scopeEnd: frame.blockEnd,
                symbolKind: .type, typeName: declaration.typeName, signature: declaration.signature
            )
        } else {
            attach(declaration, frame: frame)
        }
        if let target { push(target, frame) }
    }

    private func visitAssociatedType(_ node: SyntaxNode, _ frame: Frame) {
        let header = header(of: node)
        guard let nameNode = header.children.first(where: { $0.field == "name" && $0.node.type == "type_identifier" })?.node
        else { return }
        let declaration = makeDeclaration(
            name: nameNode.text, kind: .associatedType, node: node, nameBytes: nameNode.byteRange,
            header: header, frame: frame, bodyEnd: nil
        )
        attach(declaration, frame: frame)
    }

    private func visitImport(_ node: SyntaxNode) {
        var module: String?
        var isTestable = false
        node.enumerateChildren { child, _ in
            if child.type == "identifier", module == nil {
                var first: String?
                child.enumerateChildren { part, _ in
                    if first == nil, part.type == "simple_identifier" { first = part.text }
                }
                module = first ?? child.text
            } else if child.type == "modifiers" {
                isTestable = child.text.contains("testable")
            }
        }
        if let module {
            model.imports.append(SwiftFileModel.Import(module: module, isTestable: isTestable, bytes: node.byteRange))
        }
    }

    // MARK: Statements and closures

    private func visitLambda(_ node: SyntaxNode, _ frame: Frame) {
        var inner = frame
        inner.isLocal = true
        inner.container = nil
        inner.blockEnd = node.endByte
        node.enumerateChildren { child, field in
            guard field == "type", child.type == "lambda_function_type" else { return }
            child.enumerateChildren { list, _ in
                guard list.type == "lambda_function_type_parameters" else { return }
                list.enumerateChildren { parameterNode, _ in
                    guard parameterNode.type == "lambda_parameter" else { return }
                    let parsed = parameter(from: parameterNode)
                    guard let name = internalNameNode(of: parameterNode) else { return }
                    addBinding(
                        name: name.text, nameBytes: name.byteRange, scopeStart: node.startByte, scopeEnd: node.endByte,
                        symbolKind: .parameter, typeName: parsed.typeName, typeText: parsed.typeText
                    )
                    parameterNode.enumerateChildren { part, partField in
                        if partField == "name", part.type != "simple_identifier", part.isNamed { push(part, inner) }
                    }
                }
            }
        }
        pushChildren(of: node, frame: inner, skipFields: ["type", "captures"])
        node.enumerateChildren { child, field in
            guard field == "captures" else { return }
            child.enumerateChildren { item, _ in
                item.enumerateChildren { part, partField in
                    if partField == "value", part.isNamed { push(part, inner) }
                }
            }
        }
    }

    private func visitConditional(_ node: SyntaxNode, _ frame: Frame, bindsToEnd: Bool) {
        var children: [(node: SyntaxNode, field: String?)] = []
        node.enumerateChildren { child, field in children.append((child, field)) }
        var bodyEnd = frame.blockEnd
        for (index, entry) in children.enumerated() where entry.node.type == "statements" {
            bodyEnd = index + 1 < children.count && children[index + 1].node.type == "}"
                ? children[index + 1].node.endByte : entry.node.endByte
            break
        }
        let scopeEnd = bindsToEnd ? frame.blockEnd : bodyEnd
        var inner = frame
        inner.depth += 1
        inner.calleeLabels = nil
        var pendingName: SyntaxNode?
        var sawValueBinding = false
        func flushShorthand() {
            guard let name = pendingName else { return }
            addBinding(
                name: name.text, nameBytes: name.byteRange, scopeStart: name.endByte, scopeEnd: scopeEnd,
                symbolKind: .local, typeName: nil,
                source: SwiftChain(base: .name(name.text, at: name.startByte), steps: [.unwrap]), isConstant: true
            )
            pendingName = nil
        }
        var work: [Work] = []
        for (index, entry) in children.enumerated() {
            let child = entry.node
            guard child.isNamed else { continue }
            if entry.field == "bound_identifier" {
                flushShorthand()
                pendingName = child
                continue
            }
            if entry.field == "condition" {
                if child.type == "value_binding_pattern" {
                    sawValueBinding = true
                    continue
                }
                if child.type == "pattern" {
                    let nested = boundIdentifiers(in: child)
                    let identifiers = nested.isEmpty && sawValueBinding ? patternIdentifiers(child) : nested
                    for identifier in identifiers {
                        addBinding(
                            name: identifier.text, nameBytes: identifier.byteRange, scopeStart: child.endByte,
                            scopeEnd: scopeEnd, symbolKind: .local, typeName: nil, isConstant: true
                        )
                    }
                    continue
                }
                if let name = pendingName {
                    addBinding(
                        name: name.text, nameBytes: name.byteRange, scopeStart: child.endByte, scopeEnd: scopeEnd,
                        symbolKind: .local, typeName: nil,
                        source: SwiftChain(base: makeChain(child).base, steps: makeChain(child).steps + [.unwrap]),
                        isConstant: true
                    )
                    pendingName = nil
                }
            }
            var next = inner
            if child.type == "statements" {
                next.isLocal = true
                next.blockEnd = index + 1 < children.count && children[index + 1].node.type == "}"
                    ? children[index + 1].node.endByte : child.endByte
            }
            work.append(.visit(child, next))
        }
        flushShorthand()
        for item in work.reversed() { stack.append(item) }
    }

    private func visitFor(_ node: SyntaxNode, _ frame: Frame) {
        var children: [(node: SyntaxNode, field: String?)] = []
        node.enumerateChildren { child, field in children.append((child, field)) }
        var collection: SyntaxNode?
        var item: SyntaxNode?
        var bodyEnd = node.endByte
        for (index, entry) in children.enumerated() {
            if entry.field == "item" { item = entry.node }
            if entry.field == "collection" { collection = entry.node }
            if entry.node.type == "statements" {
                bodyEnd = index + 1 < children.count && children[index + 1].node.type == "}"
                    ? children[index + 1].node.endByte : entry.node.endByte
            }
        }
        if let item {
            let chain = collection.map { makeChain($0) }
            let names = patternIdentifiers(item)
            for name in names {
                addBinding(
                    name: name.text, nameBytes: name.byteRange, scopeStart: collection?.endByte ?? item.endByte,
                    scopeEnd: bodyEnd, symbolKind: .local, typeName: nil,
                    source: names.count == 1 ? chain : nil, sourceIsElement: names.count == 1, isConstant: true
                )
            }
        }
        var inner = frame
        inner.depth += 1
        inner.calleeLabels = nil
        var work: [Work] = []
        for (index, entry) in children.enumerated() where entry.node.isNamed {
            if entry.field == "item" { continue }
            var next = inner
            if entry.node.type == "statements" {
                next.isLocal = true
                next.blockEnd = index + 1 < children.count && children[index + 1].node.type == "}"
                    ? children[index + 1].node.endByte : entry.node.endByte
            }
            work.append(.visit(entry.node, next))
        }
        for work in work.reversed() { stack.append(work) }
    }

    private func visitCatch(_ node: SyntaxNode, _ frame: Frame) {
        var hasPattern = false
        node.enumerateChildren { child, field in
            guard field == "error", child.type == "pattern" else { return }
            hasPattern = true
            var names = boundIdentifiers(in: child)
            if names.isEmpty { names = patternIdentifiers(child) }
            for name in names {
                addBinding(
                    name: name.text, nameBytes: name.byteRange, scopeStart: child.endByte, scopeEnd: node.endByte,
                    symbolKind: .local, typeName: nil, isConstant: true
                )
            }
        }
        if !hasPattern { addImplicitBinding("error", at: node, scopeEnd: node.endByte, typeName: "Error") }
        pushChildren(of: node, frame: frame, skipFields: ["error"])
    }

    private func visitSwitchEntry(_ node: SyntaxNode, _ frame: Frame) {
        node.enumerateChildren { child, _ in
            guard child.type == "switch_pattern" else { return }
            var identifiers = boundIdentifiers(in: child)
            identifiers.append(contentsOf: letPatternIdentifiers(in: child))
            var seen = Set<Int>()
            for identifier in identifiers where seen.insert(identifier.startByte).inserted {
                addBinding(
                    name: identifier.text, nameBytes: identifier.byteRange, scopeStart: child.endByte,
                    scopeEnd: node.endByte, symbolKind: .local, typeName: nil, isConstant: true
                )
            }
        }
        var inner = frame
        inner.blockEnd = node.endByte
        inner.isLocal = true
        pushChildren(of: node, frame: inner, skipFields: [])
    }

    // MARK: Expressions

    private func visitNavigation(_ node: SyntaxNode, _ frame: Frame) {
        guard let target = node.child(byFieldName: "target"), let suffix = node.child(byFieldName: "suffix") else {
            pushChildren(of: node, frame: frame)
            return
        }
        if let name = suffix.child(byFieldName: "suffix") ?? suffix.namedChildren.first {
            let chain = makeChain(target)
            recordUse(name, role: .member(chain), calleeLabels: frame.calleeLabels)
        }
        push(target, frame)
    }

    private func visitCall(_ node: SyntaxNode, _ frame: Frame) {
        var callee: SyntaxNode?
        var rest: [SyntaxNode] = []
        node.enumerateChildren { child, _ in
            guard child.isNamed else { return }
            if callee == nil { callee = child } else { rest.append(child) }
        }
        for child in rest.reversed() { push(child, frame) }
        guard let callee else { return }
        push(callee, frame, calleeLabels: argumentLabels(of: node))
    }

    private func visitConstructor(_ node: SyntaxNode, _ frame: Frame) {
        node.enumerateChildren { child, field in
            if field == "constructed_type" {
                recordTypeUses(in: child, isCall: true)
                // The type arguments are types too.
                child.enumerateChildren { part, _ in
                    if part.type == "type_arguments" { push(part, frame) }
                }
            } else if child.isNamed {
                push(child, frame)
            }
        }
    }

    private func visitPrefix(_ node: SyntaxNode, _ frame: Frame) {
        var first: SyntaxNode?
        node.enumerateChildren { child, _ in
            if first == nil { first = child }
        }
        if let first, !first.isNamed, first.type == ".", let target = node.child(byFieldName: "target"),
           target.type == "simple_identifier" {
            recordUse(target, role: .implicitMember, calleeLabels: frame.calleeLabels)
            return
        }
        pushChildren(of: node, frame: frame)
    }

    private func recordTypeUses(in node: SyntaxNode, isCall: Bool) {
        var last: SyntaxNode?
        node.enumerateChildren { child, _ in
            if child.type == "type_identifier" { last = child }
        }
        node.enumerateChildren { child, _ in
            if child.type == "type_identifier" {
                let isLast = child.byteRange == last?.byteRange
                recordUse(child, role: .type, calleeLabels: isCall && isLast ? [] : nil)
            }
        }
    }

    private func recordUse(_ node: SyntaxNode, role: SwiftFileModel.Use.Role, calleeLabels: [String]?) {
        model.uses.append(SwiftFileModel.Use(
            name: node.text, bytes: node.byteRange, role: role,
            isCall: calleeLabels != nil, callLabels: calleeLabels ?? []
        ))
    }

    // MARK: Chains

    public func makeChain(_ start: SyntaxNode) -> SwiftChain {
        var steps: [SwiftChain.Step] = []
        var node = start
        var hops = 0
        while hops < Self.maxChainLength {
            hops += 1
            switch node.type {
            case "navigation_expression":
                guard let target = node.child(byFieldName: "target"),
                      let suffix = node.child(byFieldName: "suffix"),
                      let name = suffix.child(byFieldName: "suffix") ?? suffix.namedChildren.first else {
                    return .unknown
                }
                steps.append(.member(name.text))
                node = target
            case "call_expression":
                guard let callee = node.namedChild(at: 0) else { return .unknown }
                steps.append(.call(labels: argumentLabels(of: node)))
                node = callee
            case "postfix_expression":
                guard let target = node.child(byFieldName: "target") else { return .unknown }
                steps.append(.unwrap)
                node = target
            case "try_expression", "await_expression":
                guard let inner = node.child(byFieldName: "expr") ?? node.namedChild(at: 0) else { return .unknown }
                node = inner
            case "tuple_expression":
                let values = node.namedChildren
                guard values.count == 1 else { return .unknown }
                node = values[0]
            case "ternary_expression":
                guard let inner = node.child(byFieldName: "if_true") else { return .unknown }
                node = inner
            case "nil_coalescing_expression":
                guard let inner = node.child(byFieldName: "value") else { return .unknown }
                node = inner
            case "simple_identifier":
                return finish(.name(node.text, at: node.startByte), steps)
            case "self_expression":
                return finish(.selfValue, steps)
            case "super_expression":
                return finish(.superValue, steps)
            case "prefix_expression":
                var first: SyntaxNode?
                node.enumerateChildren { child, _ in if first == nil { first = child } }
                if let first, !first.isNamed, first.type == ".", let target = node.child(byFieldName: "target") {
                    return finish(.implicitMember(target.text), steps)
                }
                return .unknown
            case "constructor_expression":
                guard let type = node.child(byFieldName: "constructed_type"), let name = typeName(of: type) else {
                    return .unknown
                }
                var argumentList: [String] = []
                node.enumerateChildren { child, _ in
                    if child.type == "constructor_suffix" { argumentList = self.labels(inCallSuffix: child) }
                }
                steps.append(.call(labels: argumentList))
                return finish(.metatype(name), steps)
            case "as_expression":
                guard let type = node.child(byFieldName: "name"), let name = typeName(of: type) else { return .unknown }
                return finish(.instance(name), steps)
            case "integer_literal", "hex_literal", "oct_literal", "bin_literal":
                return finish(.instance("Int"), steps)
            case "real_literal":
                return finish(.instance("Double"), steps)
            case "boolean_literal":
                return finish(.instance("Bool"), steps)
            case "line_string_literal", "multi_line_string_literal", "raw_string_literal":
                return finish(.instance("String"), steps)
            case "array_literal":
                let element = node.child(byFieldName: "element")
                let inner = element.map { makeChain($0) }
                if let inner, case .instance(let name) = inner.base, inner.steps.isEmpty {
                    return finish(.instance("[\(name)]"), steps)
                }
                return finish(.instance("[?]"), steps)
            case "dictionary_literal":
                return finish(.instance("[?: ?]"), steps)
            default:
                return .unknown
            }
        }
        return .unknown
    }

    private func finish(_ base: SwiftChain.Base, _ steps: [SwiftChain.Step]) -> SwiftChain {
        SwiftChain(base: base, steps: steps.reversed())
    }

    private func argumentLabels(of call: SyntaxNode) -> [String] {
        var labels: [String] = []
        call.enumerateChildren { child, _ in
            if child.type == "call_suffix" { labels = self.labels(inCallSuffix: child) }
        }
        return labels
    }

    private func labels(inCallSuffix suffix: SyntaxNode) -> [String] {
        var labels: [String] = []
        suffix.enumerateChildren { child, _ in
            if child.type == "value_arguments" {
                child.enumerateChildren { argument, _ in
                    guard argument.type == "value_argument" else { return }
                    if let label = argument.child(byFieldName: "name") {
                        labels.append(label.namedChildren.first?.text ?? label.text)
                    } else {
                        labels.append("_")
                    }
                }
            } else if child.type == "lambda_literal" {
                labels.append("_")
            }
        }
        return labels
    }

    // MARK: Types and patterns

    /// A written type reduced to the name member lookup needs: `Int?` is `Int`, `[Int]` is
    /// `[Int]`, `[K: V]` is `[K: V]`, `some View` is `View`, `Swift.Array<Int>` is `Array`.
    /// Function, tuple and composition types have no name.
    public func typeName(of node: SyntaxNode) -> String? {
        switch node.type {
        case "type_identifier":
            return node.text
        case "user_type":
            var last: String?
            node.enumerateChildren { child, _ in
                if child.type == "type_identifier" { last = child.text }
            }
            return last
        case "optional_type":
            return (node.child(byFieldName: "wrapped") ?? node.namedChildren.first).flatMap { typeName(of: $0) }
        case "array_type":
            let element = (node.child(byFieldName: "name") ?? node.namedChildren.first).flatMap { typeName(of: $0) }
            return "[\(element ?? "?")]"
        case "dictionary_type":
            let parts = node.namedChildren.compactMap { typeName(of: $0) }
            if parts.count == 2 { return "[\(parts[0]): \(parts[1])]" }
            return "[?: ?]"
        case "opaque_type", "existential_type", "type_annotation":
            return (node.child(byFieldName: "name") ?? node.namedChildren.first).flatMap { typeName(of: $0) }
        default:
            return nil
        }
    }

    /// The identifiers a pattern declares: every `simple_identifier` leaf outside type nodes.
    private func patternIdentifiers(_ pattern: SyntaxNode) -> [SyntaxNode] {
        var result: [SyntaxNode] = []
        var pending = [pattern]
        while let node = pending.popLast() {
            if node.type == "simple_identifier" {
                if node.text != "_" { result.append(node) }
                continue
            }
            if Self.typeNodeTypes.contains(node.type) || node.type == "type_annotation" || node.type == "value_binding_pattern" {
                continue
            }
            node.enumerateChildren { child, _ in
                if child.isNamed { pending.append(child) }
            }
        }
        return result.sorted { $0.startByte < $1.startByte }
    }

    /// `case let .named(n)`, `case let (x, y)`: under a pattern that has a `let`/`var` of its own,
    /// the identifiers of its nested patterns are bound, and a direct identifier is a case name.
    private func letPatternIdentifiers(in node: SyntaxNode) -> [SyntaxNode] {
        var result: [SyntaxNode] = []
        var pending = [node]
        while let current = pending.popLast() {
            var hasBinding = false
            var nested: [SyntaxNode] = []
            current.enumerateChildren { child, _ in
                if child.type == "value_binding_pattern" { hasBinding = true }
                if child.type == "pattern" { nested.append(child) }
            }
            if hasBinding {
                for pattern in nested { result.append(contentsOf: patternIdentifiers(pattern)) }
            } else {
                pending.append(contentsOf: current.namedChildren.filter { $0.type == "pattern" })
            }
        }
        return result
    }

    /// Identifiers bound by `let x` inside a pattern (the grammar's `bound_identifier` field).
    private func boundIdentifiers(in node: SyntaxNode) -> [SyntaxNode] {
        var result: [SyntaxNode] = []
        var pending = [node]
        while let current = pending.popLast() {
            current.enumerateChildren { child, field in
                if field == "bound_identifier", child.type == "simple_identifier" {
                    result.append(child)
                } else if child.isNamed, !Self.typeNodeTypes.contains(child.type) {
                    pending.append(child)
                }
            }
        }
        return result.sorted { $0.startByte < $1.startByte }
    }

    // MARK: Bindings

    private func addBinding(
        name: String, nameBytes: Range<Int>, scopeStart: Int, scopeEnd: Int, symbolKind: SwiftFileModel.SymbolKind,
        typeName: String?, typeText: String? = nil, source: SwiftChain? = nil, sourceIsElement: Bool = false,
        isConstant: Bool = false, signature: String? = nil
    ) {
        model.bindings.append(SwiftFileModel.Binding(
            name: name, nameBytes: nameBytes, scopeStart: scopeStart, scopeEnd: max(scopeEnd, scopeStart),
            symbolKind: symbolKind, typeName: typeName, typeText: typeText, source: source,
            sourceIsElement: sourceIsElement, isConstant: isConstant, signature: signature
        ))
    }

    /// A binding with no identifier in the text (`newValue`, the implicit `error`).
    private func addImplicitBinding(_ name: String, at node: SyntaxNode, scopeEnd: Int, typeName: String? = nil) {
        addBinding(
            name: name, nameBytes: node.startByte..<node.startByte, scopeStart: node.startByte, scopeEnd: scopeEnd,
            symbolKind: .local, typeName: typeName
        )
    }
}
