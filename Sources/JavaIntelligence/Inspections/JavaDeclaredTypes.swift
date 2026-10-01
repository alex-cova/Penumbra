import EditorIntelligence
import Foundation

/// The declared type of a variable, read from the declaration in the same file. Only what the
/// syntax says: nothing is inferred, so an unknown type is `nil` and rules stay silent.
struct JavaDeclaredType: Equatable {
    /// Simple name without generics or package (`String`, `int`, `Integer`, `List`).
    let name: String
    let isArray: Bool

    static let string = JavaDeclaredType(name: "String", isArray: false)

    var isFloatingPoint: Bool { !isArray && ["double", "float", "Double", "Float"].contains(name) }
    var isBoxedNumber: Bool {
        !isArray && ["Integer", "Long", "Short", "Byte", "Double", "Float", "BigInteger", "BigDecimal"].contains(name)
    }
    var isPrimitiveNumber: Bool {
        !isArray && ["int", "long", "short", "byte", "double", "float"].contains(name)
    }
    var isIntegral: Bool { !isArray && ["int", "long", "short", "byte", "Integer", "Long", "Short", "Byte"].contains(name) }
}

/// Per-parse memo for `JavaDeclaredTypes`: each class body's field table is built once, and an
/// expression's type is resolved once however many rules ask. Without it every `==` in a
/// 400-member class rescans all 400 members.
final class JavaDeclarationCache: @unchecked Sendable {
    private struct Resolved { let type: JavaDeclaredType? }

    private let lock = NSLock()
    private var fieldTables: [Int: [String: JavaDeclaredType]] = [:]
    private var expressionTypes: [Range<Int>: Resolved] = [:]
    private var positions: JavaPositionIndex?

    func positionIndex(for bytes: [UInt8]) -> JavaPositionIndex {
        lock.lock()
        defer { lock.unlock() }
        if let positions { return positions }
        let built = JavaPositionIndex(bytes: bytes)
        positions = built
        return built
    }

    func fields(of body: SyntaxNode, build: () -> [String: JavaDeclaredType]) -> [String: JavaDeclaredType] {
        lock.lock()
        if let table = fieldTables[body.startByte] { lock.unlock(); return table }
        lock.unlock()
        let table = build()
        lock.lock()
        fieldTables[body.startByte] = table
        lock.unlock()
        return table
    }

    func expressionType(for range: Range<Int>, resolve: () -> JavaDeclaredType?) -> JavaDeclaredType? {
        lock.lock()
        if let hit = expressionTypes[range] { lock.unlock(); return hit.type }
        lock.unlock()
        let type = resolve()
        lock.lock()
        expressionTypes[range] = Resolved(type: type)
        lock.unlock()
        return type
    }
}

/// Line starts and UTF-16 offsets of a source, so turning a byte offset into a `TextPosition`
/// is a binary search plus one line's worth of work instead of decoding the whole prefix.
final class JavaPositionIndex: @unchecked Sendable {
    private let bytes: [UInt8]
    private var lineStarts: [Int] = [0]
    private var lineStartsUTF16: [Int] = [0]

    init(bytes: [UInt8]) {
        self.bytes = bytes
        var units = 0
        for (index, byte) in bytes.enumerated() {
            units += Self.utf16Units(of: byte)
            if byte == 10 {
                lineStarts.append(index + 1)
                lineStartsUTF16.append(units)
            }
        }
    }

    /// UTF-16 units a byte starts: a continuation byte none, a 4-byte lead two, any other lead one.
    private static func utf16Units(of byte: UInt8) -> Int {
        if byte & 0xC0 == 0x80 { return 0 }
        return byte >= 0xF0 ? 2 : 1
    }

    func position(forByteOffset byteOffset: Int) -> TextPosition {
        let clamped = min(max(0, byteOffset), bytes.count)
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= clamped { low = mid } else { high = mid - 1 }
        }
        var column = 0
        for index in lineStarts[low]..<clamped { column += Self.utf16Units(of: bytes[index]) }
        return TextPosition(line: low, column: column, utf16Offset: lineStartsUTF16[low] + column)
    }
}

enum JavaDeclaredTypes {
    /// The type of an expression when it is a literal, a variable, `this.field` or `variable.field`
    /// declared in this file.
    static func type(of expression: SyntaxNode) -> JavaDeclaredType? {
        let node = expression.unparenthesized
        return node.tree.declarationCache.expressionType(for: node.byteRange) { resolveType(of: node) }
    }

    private static func resolveType(of node: SyntaxNode) -> JavaDeclaredType? {
        switch node.type {
        case "string_literal": return .string
        case "character_literal": return JavaDeclaredType(name: "char", isArray: false)
        case "decimal_integer_literal", "hex_integer_literal", "octal_integer_literal", "binary_integer_literal":
            return JavaDeclaredType(name: node.text.hasSuffix("L") || node.text.hasSuffix("l") ? "long" : "int", isArray: false)
        case "decimal_floating_point_literal", "hex_floating_point_literal":
            let last = node.text.last
            return JavaDeclaredType(name: last == "f" || last == "F" ? "float" : "double", isArray: false)
        case "binary_expression":
            // `"a" + x` is a String whatever x is.
            guard let op = node.operatorText, let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right") else { return nil }
            let leftType = type(of: left)
            let rightType = type(of: right)
            if op == "+", leftType == .string || rightType == .string { return .string }
            // Arithmetic on declared numbers: floating wins, else `long` wins, else `int`.
            guard ["+", "-", "*", "/", "%"].contains(op), let leftType, let rightType, !leftType.isArray, !rightType.isArray else { return nil }
            let names = [leftType.name, rightType.name]
            if names.contains(where: { ["double", "Double"].contains($0) }) { return JavaDeclaredType(name: "double", isArray: false) }
            if names.contains(where: { ["float", "Float"].contains($0) }) { return JavaDeclaredType(name: "float", isArray: false) }
            guard leftType.isIntegral, rightType.isIntegral else { return nil }
            return JavaDeclaredType(name: names.contains(where: { ["long", "Long"].contains($0) }) ? "long" : "int", isArray: false)
        case "identifier":
            return variableType(named: node.text, at: node)
        case "field_access":
            guard let object = node.child(byFieldName: "object"), let field = node.child(byFieldName: "field") else { return nil }
            if object.type == "this" {
                guard let body = enclosingTypeBody(of: node) else { return nil }
                return fieldType(named: field.text, in: body)
            }
            if object.type == "identifier", let owner = variableType(named: object.text, at: node),
               let body = typeBody(named: owner.name, in: node.tree.rootNode) {
                return fieldType(named: field.text, in: body)
            }
            return nil
        default:
            return nil
        }
    }

    /// The nearest declaration of local, parameter or field `name` visible at `node`.
    static func variableType(named name: String, at node: SyntaxNode) -> JavaDeclaredType? {
        var child = node
        var current = node.parent
        while let scope = current {
            switch scope.type {
            case "block", "switch_block", "constructor_body":
                for statement in scope.namedChildren where statement.endByte <= child.startByte || statement.byteRange == child.byteRange {
                    if statement.type == "local_variable_declaration", let type = declaredType(in: statement, variable: name) { return type }
                }
            case "for_statement":
                if let initializer = scope.child(byFieldName: "init"), initializer.type == "local_variable_declaration",
                   let type = declaredType(in: initializer, variable: name) { return type }
            case "enhanced_for_statement":
                if scope.child(byFieldName: "name")?.text == name, let type = scope.child(byFieldName: "type") {
                    return make(type, dimensions: scope.child(byFieldName: "dimensions"))
                }
            case "method_declaration", "constructor_declaration":
                if let parameters = scope.child(byFieldName: "parameters") {
                    for parameter in parameters.namedChildren(ofType: "formal_parameter") where parameter.child(byFieldName: "name")?.text == name {
                        if let type = parameter.child(byFieldName: "type") { return make(type, dimensions: parameter.child(byFieldName: "dimensions")) }
                    }
                }
            case "class_body", "enum_body":
                if let type = fieldType(named: name, in: scope) { return type }
            default:
                break
            }
            child = scope
            current = scope.parent
        }
        return nil
    }

    static func fieldType(named name: String, in body: SyntaxNode) -> JavaDeclaredType? {
        let table = body.tree.declarationCache.fields(of: body) {
            var table: [String: JavaDeclaredType] = [:]
            for member in body.namedChildren where member.type == "field_declaration" {
                guard let type = member.child(byFieldName: "type") else { continue }
                for declarator in member.namedChildren(ofType: "variable_declarator") {
                    guard let declared = declarator.child(byFieldName: "name")?.text, table[declared] == nil,
                          let resolved = make(type, dimensions: declarator.child(byFieldName: "dimensions")) else { continue }
                    table[declared] = resolved
                }
            }
            return table
        }
        return table[name]
    }

    private static func declaredType(in declaration: SyntaxNode, variable name: String) -> JavaDeclaredType? {
        guard let type = declaration.child(byFieldName: "type") else { return nil }
        for declarator in declaration.namedChildren(ofType: "variable_declarator") where declarator.child(byFieldName: "name")?.text == name {
            return make(type, dimensions: declarator.child(byFieldName: "dimensions"))
        }
        return nil
    }

    private static func make(_ type: SyntaxNode, dimensions: SyntaxNode?) -> JavaDeclaredType? {
        let isArray = type.type == "array_type" || dimensions != nil
        let element = type.type == "array_type" ? (type.child(byFieldName: "element") ?? type) : type
        let name = simpleName(of: element)
        guard !name.isEmpty, name != "var" else { return nil }
        return JavaDeclaredType(name: name, isArray: isArray)
    }

    /// `java.util.List<String>` → `List`.
    static func simpleName(of type: SyntaxNode) -> String {
        switch type.type {
        case "generic_type":
            return type.namedChild(at: 0).map(simpleName(of:)) ?? ""
        case "scoped_type_identifier":
            return type.namedChildren.last.map(simpleName(of:)) ?? ""
        default:
            return type.text
        }
    }

    static func enclosingTypeBody(of node: SyntaxNode) -> SyntaxNode? {
        var current = node.parent
        while let candidate = current {
            if candidate.type == "class_body" || candidate.type == "enum_body" || candidate.type == "interface_body" { return candidate }
            current = candidate.parent
        }
        return nil
    }

    /// The first class, record, enum or interface called `name` anywhere in the file.
    static func typeDeclaration(named name: String, in root: SyntaxNode) -> SyntaxNode? {
        let declarations: Set<String> = ["class_declaration", "record_declaration", "enum_declaration", "interface_declaration"]
        var stack = [root]
        while let node = stack.popLast() {
            if declarations.contains(node.type), node.child(byFieldName: "name")?.text == name { return node }
            stack.append(contentsOf: node.namedChildren.reversed())
        }
        return nil
    }

    static func typeBody(named name: String, in root: SyntaxNode) -> SyntaxNode? {
        typeDeclaration(named: name, in: root)?.child(byFieldName: "body")
    }
}
