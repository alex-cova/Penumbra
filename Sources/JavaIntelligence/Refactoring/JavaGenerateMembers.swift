import EditorIntelligence
import Foundation

/// "Generate…" for Java: a constructor, getters and setters, or `toString()` written into the
/// class or enum around the caret. Works on the syntax tree of the buffer alone (no index), so
/// it is available as soon as the file parses.
enum JavaGenerateMembers {
    struct Field {
        let name: String
        let typeText: String
        let isStatic: Bool
        let isFinal: Bool
        let hasInitializer: Bool

        var isBoolean: Bool { typeText == "boolean" || typeText == "Boolean" }
    }

    /// The type the members go into and what it already declares.
    struct TypeContext {
        let tree: JavaSyntaxTree
        let source: String
        let typeDecl: SyntaxNode
        let typeName: String
        let isEnum: Bool
        let isAbstract: Bool
        let body: SyntaxNode
        /// Where the type's members live: the class body, or an enum's `enum_body_declarations`
        /// (absent for an enum that has only constants).
        let memberContainer: SyntaxNode?
        let members: [SyntaxNode]
        let fields: [Field]
        let methods: [(name: String, parameterCount: Int)]
        let constructors: [[String]]
        let caretByte: Int
    }

    private static let commentTypes: Set<String> = ["line_comment", "block_comment"]

    // MARK: - Context

    static func context(source: String, caretUTF16: Int) -> TypeContext? {
        guard !source.isEmpty, let tree = JavaSyntaxParser().parse(source) else { return nil }
        let caretByte = JavaNavigationText.utf8ByteOffset(forUTF16Offset: caretUTF16, in: source)
        guard let typeDecl = enclosingType(at: caretByte, in: tree),
              let name = typeDecl.child(byFieldName: "name")?.text,
              let body = typeDecl.child(byFieldName: "body") else { return nil }
        let isEnum = typeDecl.type == "enum_declaration"
        let container = isEnum ? body.namedChildren.first { $0.type == "enum_body_declarations" } : body
        let members = (container?.namedChildren ?? []).filter { !commentTypes.contains($0.type) }
        return TypeContext(
            tree: tree,
            source: source,
            typeDecl: typeDecl,
            typeName: name,
            isEnum: isEnum,
            isAbstract: modifierKeywords(of: typeDecl).contains("abstract"),
            body: body,
            memberContainer: container,
            members: members,
            fields: fields(in: members),
            methods: methods(in: members),
            constructors: constructors(in: members),
            caretByte: caretByte
        )
    }

    /// The innermost class or enum containing the caret; a caret outside any type (imports, file
    /// start) falls back to the file's first top-level class or enum.
    private static func enclosingType(at byte: Int, in tree: JavaSyntaxTree) -> SyntaxNode? {
        func isTarget(_ node: SyntaxNode) -> Bool {
            node.type == "class_declaration" || node.type == "enum_declaration"
        }
        var node: SyntaxNode? = tree.node(atByteOffset: byte)
        while let current = node {
            switch current.type {
            case "interface_declaration", "record_declaration", "annotation_type_declaration":
                return nil
            default:
                if isTarget(current) { return current }
            }
            node = current.parent
        }
        return tree.rootNode.namedChildren.first(where: isTarget)
    }

    private static func modifierKeywords(of node: SyntaxNode) -> Set<String> {
        guard let modifiers = node.namedChildren.first(where: { $0.type == "modifiers" }) else { return [] }
        return Set(modifiers.children.filter { !$0.isNamed }.map(\.text))
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func fields(in members: [SyntaxNode]) -> [Field] {
        var result: [Field] = []
        for member in members where member.type == "field_declaration" {
            let modifiers = modifierKeywords(of: member)
            let baseType = normalized(member.child(byFieldName: "type")?.text ?? "Object")
            for declarator in member.namedChildren(ofType: "variable_declarator") {
                guard let name = declarator.child(byFieldName: "name")?.text else { continue }
                let dimensions = normalized(declarator.child(byFieldName: "dimensions")?.text ?? "")
                    .replacingOccurrences(of: " ", with: "")
                result.append(Field(
                    name: name,
                    typeText: baseType + dimensions,
                    isStatic: modifiers.contains("static"),
                    isFinal: modifiers.contains("final"),
                    hasInitializer: declarator.child(byFieldName: "value") != nil
                ))
            }
        }
        return result
    }

    private static func parameterNodes(of declaration: SyntaxNode) -> [SyntaxNode] {
        declaration.child(byFieldName: "parameters")?.namedChildren.filter {
            $0.type == "formal_parameter" || $0.type == "spread_parameter"
        } ?? []
    }

    private static func methods(in members: [SyntaxNode]) -> [(name: String, parameterCount: Int)] {
        members.filter { $0.type == "method_declaration" }.compactMap { method in
            guard let name = method.child(byFieldName: "name")?.text else { return nil }
            return (name, parameterNodes(of: method).count)
        }
    }

    private static func constructors(in members: [SyntaxNode]) -> [[String]] {
        members.filter { $0.type == "constructor_declaration" }.map { constructor in
            parameterNodes(of: constructor).map { parameter in
                normalized(parameter.child(byFieldName: "type")?.text ?? parameter.text)
            }
        }
    }

    // MARK: - Naming

    private static func capitalized(_ name: String) -> String {
        guard let first = name.first else { return name }
        return String(first).uppercased() + name.dropFirst()
    }

    /// `isActive` is already a boolean accessor name: it becomes `isActive()` / `setActive(…)`.
    private static func booleanStem(of field: Field) -> String? {
        guard field.isBoolean, field.name.hasPrefix("is"), field.name.count > 2,
              field.name.dropFirst(2).first?.isUppercase == true else { return nil }
        return String(field.name.dropFirst(2))
    }

    static func getterName(_ field: Field) -> String {
        if booleanStem(of: field) != nil { return field.name }
        return (field.isBoolean ? "is" : "get") + capitalized(field.name)
    }

    static func setterName(_ field: Field) -> String {
        "set" + (booleanStem(of: field) ?? capitalized(field.name))
    }

    private static func hasGetter(_ field: Field, in context: TypeContext) -> Bool {
        let name = getterName(field)
        return context.methods.contains { $0.name == name && $0.parameterCount == 0 }
    }

    private static func hasSetter(_ field: Field, in context: TypeContext) -> Bool {
        let name = setterName(field)
        return context.methods.contains { $0.name == name && $0.parameterCount == 1 }
    }

    private static func hasToString(in context: TypeContext) -> Bool {
        context.methods.contains { $0.name == "toString" && $0.parameterCount == 0 }
    }

    // MARK: - Menu

    static func menu(source: String, caretUTF16: Int) -> CodeGenerationMenu? {
        guard let context = context(source: source, caretUTF16: caretUTF16) else { return nil }
        return menu(for: context)
    }

    static func menu(for context: TypeContext) -> CodeGenerationMenu {
        func descriptors(_ fields: [Field]) -> [CodeGenerationField] {
            fields.map { CodeGenerationField(name: $0.name, typeText: $0.typeText) }
        }
        let instance = context.fields.filter { !$0.isStatic }
        var options: [CodeGenerationOption] = [
            CodeGenerationOption(
                kind: .constructor, title: "Constructor",
                fields: descriptors(constructorCandidates(context)), allowsEmptySelection: true
            )
        ]
        let needsGetter = context.fields.filter { !hasGetter($0, in: context) }
        let needsSetter = context.fields.filter { !$0.isFinal && !hasSetter($0, in: context) }
        let needsEither = context.fields.filter {
            !hasGetter($0, in: context) || (!$0.isFinal && !hasSetter($0, in: context))
        }
        if !needsEither.isEmpty {
            options.append(CodeGenerationOption(kind: .getterAndSetter, title: "Getter and Setter", fields: descriptors(needsEither)))
        }
        if !needsGetter.isEmpty {
            options.append(CodeGenerationOption(kind: .getter, title: "Getter", fields: descriptors(needsGetter)))
        }
        if !needsSetter.isEmpty {
            options.append(CodeGenerationOption(kind: .setter, title: "Setter", fields: descriptors(needsSetter)))
        }
        if !instance.isEmpty, !hasToString(in: context) {
            options.append(CodeGenerationOption(kind: .toString, title: "toString()", fields: descriptors(instance)))
        }
        return CodeGenerationMenu(typeName: context.typeName, options: options)
    }

    /// Instance fields a constructor can assign; a `final` field that already has a value can't be.
    private static func constructorCandidates(_ context: TypeContext) -> [Field] {
        context.fields.filter { !$0.isStatic && !($0.isFinal && $0.hasInitializer) }
    }

    // MARK: - Plan

    static func plan(
        kind: CodeGenerationKind, fieldNames: [String], source: String, url: URL, caretUTF16: Int
    ) -> WorkspaceEditPlan {
        let title = "Generate"
        guard let context = context(source: source, caretUTF16: caretUTF16) else {
            return WorkspaceEditPlan(blockingError: "Place the caret inside a class or enum.", title: title)
        }
        let wanted = Set(fieldNames)
        func selected(from pool: [Field]) -> [Field] { pool.filter { wanted.contains($0.name) } }

        let layout = Layout(context: context)
        var methods: [[String]] = []
        switch kind {
        case .constructor:
            let fields = selected(from: constructorCandidates(context))
            let types = fields.map(\.typeText)
            if context.constructors.contains(types) {
                let signature = "\(context.typeName)(\(types.joined(separator: ", ")))"
                return WorkspaceEditPlan(blockingError: "\(signature) already exists.", title: title)
            }
            methods = [constructor(fields: fields, context: context, layout: layout)]
        case .getter:
            methods = selected(from: context.fields).filter { !hasGetter($0, in: context) }
                .map { getter($0, layout: layout) }
        case .setter:
            methods = selected(from: context.fields).filter { !$0.isFinal && !hasSetter($0, in: context) }
                .map { setter($0, context: context, layout: layout) }
        case .getterAndSetter:
            for field in selected(from: context.fields) {
                if !hasGetter(field, in: context) { methods.append(getter(field, layout: layout)) }
                if !field.isFinal, !hasSetter(field, in: context) {
                    methods.append(setter(field, context: context, layout: layout))
                }
            }
        case .toString:
            if hasToString(in: context) {
                return WorkspaceEditPlan(blockingError: "toString() already exists.", title: title)
            }
            let fields = selected(from: context.fields.filter { !$0.isStatic })
            guard !fields.isEmpty else {
                return WorkspaceEditPlan(blockingError: "Select at least one field.", title: title)
            }
            methods = [toStringMethod(fields: fields, context: context, layout: layout)]
        default:
            return WorkspaceEditPlan(blockingError: "That can't be generated.", title: title)
        }
        guard !methods.isEmpty else {
            return WorkspaceEditPlan(
                blockingError: "Nothing to generate: the selected fields already have those methods.", title: title
            )
        }

        let block = methods
            .map { lines in lines.map { $0.isEmpty ? $0 : layout.memberIndent + $0 }.joined(separator: "\n") }
            .joined(separator: "\n\n")
        let insertion = insertion(of: block, kind: kind, context: context, layout: layout)
        let entry = JavaRefactoringText.planEntry(
            url: url, byteRange: insertion.range, oldText: insertion.oldText, newText: insertion.newText,
            source: source, description: description(of: kind)
        )
        return WorkspaceEditPlan(entries: [entry], title: title)
    }

    private static func description(of kind: CodeGenerationKind) -> String {
        switch kind {
        case .constructor: return "Insert constructor"
        case .toString: return "Insert toString()"
        default: return "Insert accessors"
        }
    }

    // MARK: - Member text

    /// Indentation of the members and one nesting step; generated lines are relative to the member indent.
    private struct Layout {
        let typeIndent: String
        let memberIndent: String
        let unit: String

        init(context: TypeContext) {
            typeIndent = JavaExtractExpression.leadingIndent(forNode: context.typeDecl, in: context.source)
            let fallbackUnit = typeIndent.contains("\t") ? "\t" : "    "
            if let first = context.members.first {
                let indent = JavaExtractExpression.leadingIndent(forNode: first, in: context.source)
                memberIndent = indent
                let step = indent.hasPrefix(typeIndent) ? String(indent.dropFirst(typeIndent.count)) : ""
                unit = step.isEmpty ? fallbackUnit : step
            } else {
                unit = fallbackUnit
                memberIndent = typeIndent + fallbackUnit
            }
        }
    }

    private static func constructor(fields: [Field], context: TypeContext, layout: Layout) -> [String] {
        // An enum constructor is implicitly private; an abstract class's can't be called directly.
        let access = context.isEnum ? "" : (context.isAbstract ? "protected " : "public ")
        let parameters = fields.map { "\($0.typeText) \($0.name)" }.joined(separator: ", ")
        return ["\(access)\(context.typeName)(\(parameters)) {"]
            + fields.map { "\(layout.unit)this.\($0.name) = \($0.name);" }
            + ["}"]
    }

    private static func getter(_ field: Field, layout: Layout) -> [String] {
        let modifier = field.isStatic ? "public static " : "public "
        let value = field.isStatic ? field.name : "this.\(field.name)"
        return [
            "\(modifier)\(field.typeText) \(getterName(field))() {",
            "\(layout.unit)return \(value);",
            "}"
        ]
    }

    private static func setter(_ field: Field, context: TypeContext, layout: Layout) -> [String] {
        let modifier = field.isStatic ? "public static " : "public "
        let target = field.isStatic ? "\(context.typeName).\(field.name)" : "this.\(field.name)"
        return [
            "\(modifier)void \(setterName(field))(\(field.typeText) \(field.name)) {",
            "\(layout.unit)\(target) = \(field.name);",
            "}"
        ]
    }

    private static func toStringMethod(fields: [Field], context: TypeContext, layout: Layout) -> [String] {
        let unit = layout.unit
        let continuation = unit + unit + unit
        func value(_ field: Field) -> String {
            guard field.typeText.hasSuffix("[]") else { return field.name }
            let multiDimensional = field.typeText.components(separatedBy: "[]").count > 2
            return "java.util.Arrays.\(multiDimensional ? "deepToString" : "toString")(\(field.name))"
        }
        var lines = ["@Override", "public String toString() {"]
        var parts: [String] = []
        for (position, field) in fields.enumerated() {
            let label = (position == 0 ? "" : ", ") + field.name + "="
            if field.typeText == "String" || field.typeText == "java.lang.String" {
                parts.append("\"\(label)'\" + \(value(field)) + '\\''")
            } else {
                parts.append("\"\(label)\" + \(value(field))")
            }
        }
        lines.append("\(unit)return \"\(context.typeName){\" +")
        for part in parts { lines.append("\(continuation)\(part) +") }
        lines.append("\(continuation)'}';")
        lines.append("}")
        return lines
    }

    // MARK: - Placement

    private struct Insertion {
        let range: Range<Int>
        let oldText: String
        let newText: String
    }

    /// Where the block goes. With the caret in the body, after the member it is in (or the last
    /// one before it); with the caret elsewhere, a constructor goes after the last field and the
    /// rest at the end of the type.
    private static func insertion(
        of block: String, kind: CodeGenerationKind, context: TypeContext, layout: Layout
    ) -> Insertion {
        let bytes = context.tree.sourceBytes
        let caretInBody = context.body.startByte < context.caretByte && context.caretByte < context.body.endByte
        let chosen: SyntaxNode?
        if caretInBody {
            chosen = context.members.last { $0.startByte <= context.caretByte }
        } else if kind == .constructor {
            chosen = context.members.last { $0.type == "field_declaration" }
        } else {
            chosen = context.members.last
        }

        let close = context.body.endByte - 1
        func after(_ position: Int, prefix: String) -> Insertion {
            // Nothing but whitespace up to the closing brace: the block takes its place, so the
            // brace doesn't end up behind a stray blank line.
            if position <= close, context.tree.text(in: position..<close).allSatisfy(\.isWhitespace) {
                return Insertion(
                    range: position..<close, oldText: context.tree.text(in: position..<close),
                    newText: prefix + block + "\n" + layout.typeIndent
                )
            }
            let text = prefix + block + (needsBlankLine(after: position, in: bytes) ? "\n" : "")
            return Insertion(range: position..<position, oldText: "", newText: text)
        }

        if let chosen {
            return after(endOfLine(ifOnlyCommentFollows: chosen.endByte, in: bytes), prefix: "\n\n")
        }
        // No member to go after: the type's body is empty, or the caret is above every member.
        let open = context.body.startByte + 1
        guard let container = context.memberContainer else {
            // An enum with constants only: the members need a `;` after the last constant.
            if let last = context.body.children.last(where: { $0.type == "enum_constant" || $0.text == "," }) {
                return after(last.endByte, prefix: ";\n\n")
            }
            return emptyBody(open: open, close: close, block: block, context: context, layout: layout)
        }
        if context.isEnum {
            let semicolon = container.children.first { $0.text == ";" }
            return after(semicolon?.endByte ?? container.startByte, prefix: "\n\n")
        }
        if context.members.isEmpty {
            return emptyBody(open: open, close: close, block: block, context: context, layout: layout)
        }
        return after(open, prefix: "\n")
    }

    /// `{}` or `{ }`: the block is set on its own lines and the closing brace stays with the type.
    private static func emptyBody(
        open: Int, close: Int, block: String, context: TypeContext, layout: Layout
    ) -> Insertion {
        let between = close >= open ? context.tree.text(in: open..<close) : ""
        if between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Insertion(
                range: open..<max(open, close), oldText: between, newText: "\n" + block + "\n" + layout.typeIndent
            )
        }
        return Insertion(range: open..<open, oldText: "", newText: "\n" + block)
    }

    /// The end of the line when nothing but a `//` comment follows `position` on it, so a trailing
    /// comment stays with its member.
    private static func endOfLine(ifOnlyCommentFollows position: Int, in bytes: [UInt8]) -> Int {
        var index = position
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 }
        if index >= bytes.count || bytes[index] == 0x0A || bytes[index] == 0x0D { return index }
        guard bytes[index] == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2F else { return position }
        while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
        return index
    }

    /// Whether the code after `position` sits closer than a blank line, so the block needs one
    /// of its own before it.
    private static func needsBlankLine(after position: Int, in bytes: [UInt8]) -> Bool {
        var index = position
        var newlines = 0
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            if bytes[index] == 0x0A { newlines += 1 }
            index += 1
        }
        guard index < bytes.count, bytes[index] != 0x7D else { return false }
        return newlines < 2
    }
}
