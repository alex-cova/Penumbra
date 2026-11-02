import Foundation

/// Simple names of a method descriptor's parameters, in the spelling `JavaTypeKeys` uses for source
/// (`(ILjava/util/List;[Lfoo/Outer$Inner;)V` → `int, List, Inner[]`).
enum JavaBytecodeDescriptor {
    static func parameterKeys(_ descriptor: String) -> [String] {
        var keys: [String] = []
        var index = descriptor.startIndex
        guard index < descriptor.endIndex, descriptor[index] == "(" else { return [] }
        index = descriptor.index(after: index)
        while index < descriptor.endIndex, descriptor[index] != ")" {
            var dimensions = 0
            while index < descriptor.endIndex, descriptor[index] == "[" {
                dimensions += 1
                index = descriptor.index(after: index)
            }
            guard index < descriptor.endIndex else { break }
            let key: String
            if descriptor[index] == "L" {
                let end = descriptor[index...].firstIndex(of: ";") ?? descriptor.endIndex
                let name = String(descriptor[descriptor.index(after: index)..<end])
                key = simpleName(ofInternalName: name)
                index = end < descriptor.endIndex ? descriptor.index(after: end) : end
            } else {
                key = primitive(descriptor[index])
                index = descriptor.index(after: index)
            }
            keys.append(key + String(repeating: "[]", count: dimensions))
        }
        return keys
    }

    /// `a/b/Outer$Inner` → `Inner`.
    static func simpleName(ofInternalName name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? name
        return last.split(separator: "$").last.map(String.init) ?? last
    }

    /// `a/b/Outer$Inner` → `Outer.Inner`.
    static func displayName(ofInternalName name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? name
        return last.replacingOccurrences(of: "$", with: ".")
    }

    static func package(ofInternalName name: String) -> String {
        name.split(separator: "/").dropLast().joined(separator: ".")
    }

    private static func primitive(_ character: Character) -> String {
        switch character {
        case "B": "byte"
        case "C": "char"
        case "D": "double"
        case "F": "float"
        case "I": "int"
        case "J": "long"
        case "S": "short"
        case "Z": "boolean"
        default: "void"
        }
    }
}

/// Maps between a decompiled tab's text and bytecode identities: the method, field or class a caret
/// is in, and where a given one is declared. The text is Sunflower's output for `thisName`, so the
/// declarations in it line up with that class file (and, for nested types, its `$` siblings).
struct JavaBytecodeSymbolLocator {
    let source: String
    /// Internal name of the class file the text was decompiled from.
    let thisName: String
    let container: JavaClassContainer

    private static let typeDeclarations: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration", "record_declaration",
        "annotation_type_declaration"
    ]
    private static let bodies: Set<String> = [
        "class_body", "interface_body", "enum_body", "enum_body_declarations", "annotation_type_body"
    ]
    /// Members whose own children can hold a local or anonymous class.
    private static let memberDeclarations: Set<String> = [
        "method_declaration", "constructor_declaration", "compact_constructor_declaration",
        "field_declaration", "enum_constant"
    ]

    private final class ClassCache {
        var classes: [String: JavaBytecodeClass?] = [:]
    }
    private let cache = ClassCache()

    private func parsed(_ owner: String) -> JavaBytecodeClass? {
        if let cached = cache.classes[owner] { return cached }
        let value = container.data(for: container.entry(forInternalName: owner))
            .flatMap { JavaBytecodeReader.parse($0, includeBodies: false) }
        cache.classes[owner] = .some(value)
        return value
    }

    // MARK: - Caret → target

    func target(atUTF16Offset offset: Int) -> JavaBytecodeTarget? {
        guard let tree = JavaSyntaxParser().parse(source) else { return nil }
        let byte = JavaNavigationText.utf8ByteOffset(forUTF16Offset: offset, in: source)
        var current: SyntaxNode? = tree.node(atByteOffset: byte)
        var typeFallback: JavaBytecodeTarget?
        while let node = current {
            if Self.memberDeclarations.contains(node.type) || Self.typeDeclarations.contains(node.type),
               let target = resolve(node, nearestByte: byte) {
                // A caret inside a member means that member; a type counts only when the caret is
                // on its name or in no member of it.
                if Self.typeDeclarations.contains(node.type) {
                    typeFallback = typeFallback ?? target
                    if let name = node.child(byFieldName: "name"), name.startByte <= byte, byte <= name.endByte { return target }
                } else {
                    return target
                }
            }
            current = node.parent
        }
        return typeFallback
    }

    // MARK: - Target → declaration

    /// Byte range of the name where `target` is declared in the text.
    func nameRange(of target: JavaBytecodeTarget) -> Range<Int>? {
        guard let tree = JavaSyntaxParser().parse(source) else { return nil }
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            if Self.memberDeclarations.contains(node.type) || Self.typeDeclarations.contains(node.type) {
                for candidate in declaredNames(of: node) where resolve(node, nearestByte: candidate.start) == target {
                    return candidate.start..<candidate.end
                }
            }
            for index in (0..<node.namedChildCount).reversed() { stack.append(node.namedChild(at: index)!) }
        }
        return nil
    }

    private func declaredNames(of node: SyntaxNode) -> [(start: Int, end: Int)] {
        switch node.type {
        case "field_declaration":
            return node.namedChildren.filter { $0.type == "variable_declarator" }
                .compactMap { $0.child(byFieldName: "name") }.map { ($0.startByte, $0.endByte) }
        default:
            return node.child(byFieldName: "name").map { [($0.startByte, $0.endByte)] } ?? []
        }
    }

    // MARK: - Resolution

    /// The bytecode identity of a declaration node, or nil for a local or anonymous class's member
    /// (its class file name is not knowable from the text) or one the class file does not have.
    private func resolve(_ node: SyntaxNode, nearestByte byte: Int) -> JavaBytecodeTarget? {
        if Self.typeDeclarations.contains(node.type) {
            guard let owner = internalName(ofTypeDeclaration: node) else { return nil }
            return JavaBytecodeTarget(kind: .type, owner: owner)
        }
        guard let typeNode = enclosingType(of: node), let owner = internalName(ofTypeDeclaration: typeNode),
              let declaring = parsed(owner) else { return nil }
        switch node.type {
        case "field_declaration":
            let declarators = node.namedChildren.filter { $0.type == "variable_declarator" }
            let names = declarators.compactMap { declarator -> (String, SyntaxNode)? in
                declarator.child(byFieldName: "name").map { ($0.text, $0) }
            }
            let chosen = names.first { $0.1.startByte <= byte && byte <= $0.1.endByte } ?? names.first
            return chosen.flatMap { field(named: $0.0, in: declaring) }
        case "enum_constant":
            return node.child(byFieldName: "name").flatMap { field(named: $0.text, in: declaring) }
        case "constructor_declaration", "compact_constructor_declaration":
            return method(named: "<init>", node: node, in: declaring, typeNode: typeNode)
        default:
            guard let name = node.child(byFieldName: "name")?.text else { return nil }
            return method(named: name, node: node, in: declaring, typeNode: typeNode)
        }
    }

    private func field(named name: String, in declaring: JavaBytecodeClass) -> JavaBytecodeTarget? {
        declaring.fields.first { $0.name == name }.map {
            JavaBytecodeTarget(kind: .field, owner: declaring.name, name: $0.name, descriptor: $0.descriptor)
        }
    }

    private func method(
        named name: String, node: SyntaxNode, in declaring: JavaBytecodeClass, typeNode: SyntaxNode
    ) -> JavaBytecodeTarget? {
        let wanted = JavaTypeKeys.keys(of: node)
        let typeVariables = typeParameterNames(of: node)
        var best: (member: JavaBytecodeClass.Member, score: Int)?
        for member in declaring.methods where member.name == name {
            let keys = JavaBytecodeDescriptor.parameterKeys(member.descriptor)
            // Inner-class and enum constructors carry leading synthetic parameters.
            guard keys.count >= wanted.count else { continue }
            let tail = Array(keys.suffix(wanted.count))
            var score = 0
            var fits = true
            for (written, actual) in zip(wanted, tail) {
                if written == actual {
                    score += 2
                } else if typeVariables.contains(written.replacingOccurrences(of: "[]", with: ""))
                            || actual == "Object" || actual.hasSuffix("Object[]") {
                    score += 1
                } else {
                    fits = false
                    break
                }
            }
            guard fits else { continue }
            if member.isSynthetic { score -= 1 }
            if keys.count == wanted.count { score += 1 }
            if best == nil || score > best!.score { best = (member, score) }
        }
        return best.map {
            JavaBytecodeTarget(kind: .method, owner: declaring.name, name: $0.member.name, descriptor: $0.member.descriptor)
        }
    }

    private func typeParameterNames(of node: SyntaxNode) -> Set<String> {
        var names: Set<String> = []
        var current: SyntaxNode? = node
        while let walk = current {
            if let parameters = walk.child(byFieldName: "type_parameters") {
                for parameter in parameters.namedChildren where parameter.type == "type_parameter" {
                    if let first = parameter.namedChildren.first { names.insert(first.text) }
                }
            }
            current = walk.parent
        }
        return names
    }

    // MARK: - Names

    /// The type declaration a member sits directly in.
    private func enclosingType(of member: SyntaxNode) -> SyntaxNode? {
        guard var parent = member.parent else { return nil }
        while Self.bodies.contains(parent.type) {
            guard let next = parent.parent else { return nil }
            parent = next
        }
        return Self.typeDeclarations.contains(parent.type) ? parent : nil
    }

    /// `thisName` for the outermost declaration of the text, `Outer$Inner` for one nested in it by
    /// member declarations only. A class declared inside a method or as an anonymous body has no name
    /// the text can give, so it is nil.
    private func internalName(ofTypeDeclaration node: SyntaxNode) -> String? {
        var nested: [String] = []
        var current = node
        while true {
            guard let name = current.child(byFieldName: "name")?.text else { return nil }
            guard var parent = current.parent else { return nil }
            var passedBody = false
            while Self.bodies.contains(parent.type) {
                passedBody = true
                guard let next = parent.parent else { return nil }
                parent = next
            }
            if Self.typeDeclarations.contains(parent.type), passedBody {
                nested.append(name)
                current = parent
                continue
            }
            // Outermost: it must stand at the top of the file.
            guard parent.type == "program" else { return nil }
            return ([thisName] + nested.reversed()).joined(separator: "$")
        }
    }
}
