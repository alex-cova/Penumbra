import Foundation

/// The members Lombok adds at compile time, which never appear in the source (F16): accessors from
/// `@Getter`, `@Setter`, `@Data` and `@Value`, and constructors from `@NoArgsConstructor`,
/// `@AllArgsConstructor`, `@RequiredArgsConstructor`, `@Data` and `@Value`. They are added to the
/// class stub the way javac's own synthesized record members are, so completion, hover and type
/// resolution (`person.getName().length()`) see them.
///
/// Only the file's own imports decide it is Lombok (`import lombok.*` or `import lombok.Getter`);
/// `@Accessors(fluent = true, chain = true)` is honoured. Not modelled: `@Builder`, `@With`,
/// `@SneakyThrows`, `val`, delombok-style `onMethod`, and a field named `$…`.
enum JavaLombokMembers {
    private static let classAnnotations: Set<String> = [
        "Getter", "Setter", "Data", "Value", "NoArgsConstructor", "AllArgsConstructor", "RequiredArgsConstructor", "Accessors"
    ]

    private struct Annotation {
        let name: String
        let arguments: String
    }

    private struct FieldInfo {
        let name: String
        let type: JavaTypeRef
        let modifiers: JavaModifiers
        let hasInitializer: Bool
        let annotations: [Annotation]
    }

    static func synthesize(
        classNode: SyntaxNode, body: SyntaxNode?, selfType: JavaTypeRef, existing methods: [JavaMethodStub]
    ) -> [JavaMethodStub] {
        let classLevel = annotations(in: classNode.namedChildren.first { $0.type == "modifiers" })
        let fields = body.map(fieldInfos) ?? []
        guard classLevel.contains(where: { classAnnotations.contains($0.name) })
                || fields.contains(where: { $0.annotations.contains { $0.name == "Getter" || $0.name == "Setter" } }),
              importsLombok(classNode) else { return [] }

        func has(_ name: String) -> Annotation? { classLevel.first { $0.name == name } }
        let data = has("Data") != nil
        let value = has("Value") != nil
        let accessors = has("Accessors")?.arguments ?? ""
        let fluent = accessors.range(of: #"fluent\s*=\s*true"#, options: .regularExpression) != nil
        let chain = fluent || accessors.range(of: #"chain\s*=\s*true"#, options: .regularExpression) != nil

        // Lombok skips a name the class already declares; its own getter and setter may share one (fluent).
        let declared = Set(methods.map(\.name))
        var result: [JavaMethodStub] = []

        for field in fields where !field.name.hasPrefix("$") {
            let isStatic = field.modifiers.contains(.staticFlag)
            let fieldGetter = field.annotations.first { $0.name == "Getter" }
            let fieldSetter = field.annotations.first { $0.name == "Setter" }
            // A class-level annotation covers non-static fields; a static field needs its own.
            let wantsGetter = fieldGetter != nil || (!isStatic && (has("Getter") != nil || data || value))
            let wantsSetter = fieldSetter != nil || (!isStatic && (has("Setter") != nil || (data && !field.modifiers.contains(.finalFlag))))
            let isBoolean: Bool = { if case .primitive(.boolean) = field.type { return true } else { return false } }()

            if wantsGetter, let access = accessLevel(of: fieldGetter ?? has("Getter")), let flags = access {
                let name = fluent ? field.name : getterName(for: field.name, isBoolean: isBoolean)
                if !declared.contains(name) {
                    result.append(JavaMethodStub(
                        name: name, parameters: [], returnType: field.type,
                        modifiers: flags.union(isStatic ? [.staticFlag] : [])
                    ))
                }
            }
            if wantsSetter, !field.modifiers.contains(.finalFlag), let access = accessLevel(of: fieldSetter ?? has("Setter")), let flags = access {
                let name = fluent ? field.name : "set" + capitalized(setterBase(for: field.name, isBoolean: isBoolean))
                if !declared.contains(name) {
                    result.append(JavaMethodStub(
                        name: name, parameters: [JavaParameterStub(name: field.name, type: field.type)],
                        returnType: chain ? selfType : .void, modifiers: flags.union(isStatic ? [.staticFlag] : [])
                    ))
                }
            }
        }

        // Constructors. `@Data` and `@Value` leave an explicit constructor alone.
        let hasExplicitConstructor = methods.contains { $0.isConstructor }
        let instanceFields = fields.filter { !$0.modifiers.contains(.staticFlag) && !$0.name.hasPrefix("$") }
        let simple: String = { if case .classType(let name, _, _) = selfType { return String(name.split(separator: ".").last ?? "") } else { return "" } }()
        func constructor(_ parameters: [FieldInfo], of annotation: Annotation?) -> JavaMethodStub {
            let flags = accessLevel(of: annotation).flatMap { $0 } ?? [.publicFlag]
            return JavaMethodStub(
                name: simple, parameters: parameters.map { JavaParameterStub(name: $0.name, type: $0.type) },
                returnType: .void, modifiers: flags, isConstructor: true
            )
        }
        var constructors: [JavaMethodStub] = []
        if let annotation = has("NoArgsConstructor") { constructors.append(constructor([], of: annotation)) }
        if let annotation = has("AllArgsConstructor") {
            constructors.append(constructor(instanceFields.filter { !($0.modifiers.contains(.finalFlag) && $0.hasInitializer) }, of: annotation))
        }
        let required = instanceFields.filter {
            ($0.modifiers.contains(.finalFlag) && !$0.hasInitializer) || $0.annotations.contains { $0.name == "NonNull" }
        }
        if let annotation = has("RequiredArgsConstructor") {
            constructors.append(constructor(required, of: annotation))
        } else if (data || value), !hasExplicitConstructor, constructors.isEmpty {
            constructors.append(constructor(value ? instanceFields.filter { !$0.hasInitializer || !$0.modifiers.contains(.finalFlag) } : required, of: nil))
        }
        for candidate in constructors where !methods.contains(where: { $0.isConstructor && $0.parameters.map(\.type) == candidate.parameters.map(\.type) })
            && !result.contains(where: { $0.isConstructor && $0.parameters.map(\.type) == candidate.parameters.map(\.type) }) {
            result.append(candidate)
        }
        return result
    }

    // MARK: - Names

    /// Lombok: a primitive `boolean` field `active` has `isActive()`; one already named `isActive`
    /// keeps that name (and its setter is `setActive`). Everything else is `getX`.
    static func getterName(for field: String, isBoolean: Bool) -> String {
        guard isBoolean else { return "get" + capitalized(field) }
        if hasIsPrefix(field) { return field }
        return "is" + capitalized(field)
    }

    private static func setterBase(for field: String, isBoolean: Bool) -> String {
        isBoolean && hasIsPrefix(field) ? String(field.dropFirst(2)) : field
    }

    private static func hasIsPrefix(_ field: String) -> Bool {
        field.hasPrefix("is") && field.dropFirst(2).first?.isUppercase == true
    }

    private static func capitalized(_ name: String) -> String {
        name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: - Reading the tree

    /// Nil when the annotation is `AccessLevel.NONE` (nothing generated); otherwise its modifiers.
    /// The outer optional is "no annotation": the caller never asks in that case.
    private static func accessLevel(of annotation: Annotation?) -> JavaModifiers?? {
        guard let annotation else { return .some(.some([.publicFlag])) }
        guard let level = annotation.arguments.range(of: #"AccessLevel\.(\w+)"#, options: .regularExpression)
            .map({ String(annotation.arguments[$0]).components(separatedBy: ".").last ?? "" }) else {
            return .some(.some([.publicFlag]))
        }
        switch level {
        case "NONE": return .some(nil)
        case "PROTECTED": return .some(.some([.protectedFlag]))
        case "PRIVATE": return .some(.some([.privateFlag]))
        case "PACKAGE": return .some(.some([]))
        default: return .some(.some([.publicFlag]))
        }
    }

    private static func annotations(in modifiers: SyntaxNode?) -> [Annotation] {
        guard let modifiers else { return [] }
        return modifiers.namedChildren
            .filter { $0.type == "marker_annotation" || $0.type == "annotation" }
            .compactMap { node in
                guard let name = node.child(byFieldName: "name")?.text else { return nil }
                return Annotation(name: String(name.split(separator: ".").last ?? ""), arguments: node.child(byFieldName: "arguments")?.text ?? "")
            }
    }

    private static func fieldInfos(in body: SyntaxNode) -> [FieldInfo] {
        var result: [FieldInfo] = []
        for member in body.namedChildren where member.type == "field_declaration" {
            guard let typeNode = member.child(byFieldName: "type") else { continue }
            let type = JavaTypeNodeConverter.convert(typeNode)
            let modifierNode = member.namedChildren.first { $0.type == "modifiers" }
            var modifiers: JavaModifiers = []
            for child in modifierNode?.children ?? [] {
                switch child.type {
                case "static": modifiers.insert(.staticFlag)
                case "final": modifiers.insert(.finalFlag)
                default: break
                }
            }
            let notes = annotations(in: modifierNode)
            for declarator in member.namedChildren(ofType: "variable_declarator") {
                guard let name = declarator.child(byFieldName: "name")?.text else { continue }
                result.append(FieldInfo(
                    name: name, type: type, modifiers: modifiers,
                    hasInitializer: declarator.child(byFieldName: "value") != nil, annotations: notes
                ))
            }
        }
        return result
    }

    private static func importsLombok(_ node: SyntaxNode) -> Bool {
        var root = node
        while let parent = root.parent { root = parent }
        return root.namedChildren.contains { $0.type == "import_declaration" && $0.text.contains("lombok") }
    }
}
