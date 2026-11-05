import Foundation

/// The members Lombok adds at compile time, which never appear in the source (F16): accessors from
/// `@Getter`, `@Setter`, `@Data` and `@Value`, constructors from `@NoArgsConstructor`,
/// `@AllArgsConstructor`, `@RequiredArgsConstructor`, `@Data` and `@Value`, `withX` copies from
/// `@With`, and a `builder()` entry point plus a `*Builder` nested class from `@Builder`. They
/// are added to the class stub the way javac's own synthesized record members are, so
/// completion, hover and type resolution (`person.getName().length()`,
/// `Person.builder().name("x").build()`) see them.
///
/// Only the file's own imports decide it is Lombok (`import lombok.*` or `import lombok.Getter`);
/// `@Accessors(fluent = true, chain = true)` is honoured. Class-level `@Builder` only (not on
/// constructors/methods), default `builder`/`build` names unless `builderMethodName`,
/// `buildMethodName` or `builderClassName` say otherwise; no `@Singular`, `toBuilder`,
/// `@SneakyThrows`, `val`, delombok-style `onMethod`, or a field named `$…`.
enum JavaLombokMembers {
    private static let classAnnotations: Set<String> = [
        "Getter", "Setter", "Data", "Value", "NoArgsConstructor", "AllArgsConstructor", "RequiredArgsConstructor", "Accessors",
        "Builder", "With", "UtilityClass"
    ]

    private struct Annotation {
        let name: String
        let arguments: String
        let range: Range<Int>?
    }

    private struct FieldInfo {
        let name: String
        let type: JavaTypeRef
        let modifiers: JavaModifiers
        let hasInitializer: Bool
        let annotations: [Annotation]
    }

    static func synthesize(
        classNode: SyntaxNode, body: SyntaxNode?, selfType: JavaTypeRef, existing methods: [JavaMethodStub],
        packageName: String, url: URL
    ) -> (methods: [JavaMethodStub], nested: [JavaClassStub]) {
        let classLevel = annotations(in: classNode.namedChildren.first { $0.type == "modifiers" })
        let fields = body.map(fieldInfos) ?? []
        guard classLevel.contains(where: { classAnnotations.contains($0.name) })
                || fields.contains(where: {
                    $0.annotations.contains { $0.name == "Getter" || $0.name == "Setter" || $0.name == "With" }
                }),
              importsLombok(classNode) else { return ([], []) }

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

        // `@With`: `withField(value)` returns a copy with one field changed. Final fields are
        // fine (copies don't assign); static fields are skipped like everywhere else here.
        let classWith = has("With")
        if classWith != nil || fields.contains(where: { $0.annotations.contains { $0.name == "With" } }) {
            for field in fields where !field.modifiers.contains(.staticFlag) && !field.name.hasPrefix("$") {
                let fieldWith = field.annotations.first { $0.name == "With" }
                guard fieldWith != nil || classWith != nil else { continue }
                guard let access = accessLevel(of: fieldWith ?? classWith), let flags = access else { continue }
                let name = "with" + capitalized(setterBase(for: field.name, isBoolean: isBooleanField(field.type)))
                if !declared.contains(name) {
                    result.append(JavaMethodStub(
                        name: name, parameters: [JavaParameterStub(name: field.name, type: field.type)],
                        returnType: selfType, modifiers: flags
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
        // `@UtilityClass` seals the class behind a private constructor (the members stay as
        // written; only the instantiation entry point is synthesized).
        if has("UtilityClass") != nil, !hasExplicitConstructor {
            constructors.append(JavaMethodStub(
                name: simple, parameters: [], returnType: .void, modifiers: [.privateFlag], isConstructor: true
            ))
        }
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

        // `@Builder`: a static entry point on the class plus the chained `*Builder`
        // nested class from `builderParts` below; the caller appends the nested stub.
        var nested: [JavaClassStub] = []
        if has("Builder") != nil,
           let parts = Self.builderParts(classNode: classNode, body: body, selfType: selfType, packageName: packageName, url: url) {
            if let entry = parts.entryPoint, !declared.contains(entry.name) {
                result.append(entry)
            }
            if let builder = parts.nested {
                nested.append(builder)
            }
        }
        return (result, nested)
    }

    /// The `@Builder` static entry point and nested builder class for `selfType`.
    ///
    /// The builder class is named `<Simple>Builder` (or `builderClassName`), holds one
    /// chainable setter per non-static field plus `build()` (or `buildMethodName`), and the
    /// entry point (`builder` or `builderMethodName`) is static on the enclosing class.
    /// `nil` when the class is not a plain `C` with a resolvable qualified name.
    private static func builderParts(
        classNode: SyntaxNode, body: SyntaxNode?, selfType: JavaTypeRef, packageName: String, url: URL
    ) -> (entryPoint: JavaMethodStub?, nested: JavaClassStub?)? {
        guard case .classType(let qualifiedName, _, _) = selfType, !qualifiedName.isEmpty else { return nil }
        let classLevel = annotations(in: classNode.namedChildren.first { $0.type == "modifiers" })
        guard let builder = classLevel.first(where: { $0.name == "Builder" }) else { return nil }
        let access = accessLevel(of: builder).flatMap { $0 } ?? [.publicFlag]
        let simple = String(qualifiedName.split(separator: ".").last ?? "")
        let builderSimpleName = stringArgument("builderClassName", in: builder.arguments) ?? (simple + "Builder")
        let builderQualifiedName = qualifiedName + "." + builderSimpleName
        let builderType = JavaTypeRef.classType(qualifiedName: builderQualifiedName, arguments: [], outer: nil)
        let entryPoint = JavaMethodStub(
            name: stringArgument("builderMethodName", in: builder.arguments) ?? "builder",
            parameters: [], returnType: builderType, modifiers: access.union([.staticFlag])
        )
        let fields = (body.map(fieldInfos) ?? []).filter { !$0.modifiers.contains(.staticFlag) && !$0.name.hasPrefix("$") }
        var builderMethods = fields.map { field in
            JavaMethodStub(
                name: field.name, parameters: [JavaParameterStub(name: field.name, type: field.type)],
                returnType: builderType, modifiers: access
            )
        }
        builderMethods.append(JavaMethodStub(
            name: stringArgument("buildMethodName", in: builder.arguments) ?? "build",
            parameters: [], returnType: selfType, modifiers: access
        ))
        let nested = JavaClassStub(
            binaryName: builderQualifiedName, qualifiedName: builderQualifiedName, simpleName: builderSimpleName,
            packageName: packageName, outerQualifiedName: qualifiedName, kind: .classKind,
            modifiers: access.union([.staticFlag]), methods: builderMethods,
            origin: .source(url, nameRange: builder.range ?? classNode.byteRange)
        )
        return (entryPoint, nested)
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
                return Annotation(
                    name: String(name.split(separator: ".").last ?? ""),
                    arguments: node.child(byFieldName: "arguments")?.text ?? "",
                    range: node.byteRange
                )
            }
    }

    private static func isBooleanField(_ type: JavaTypeRef) -> Bool {
        if case .primitive(.boolean) = type { return true } else { return false }
    }

    /// `key = "value"` inside an annotation argument list, e.g. `builderClassName`.
    private static func stringArgument(_ key: String, in arguments: String) -> String? {
        guard let range = arguments.range(of: key + #"\s*=\s*""#, options: .regularExpression) else { return nil }
        let rest = arguments[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
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

    /// Whether the file containing `node` imports from Lombok: the gate for every `val`
    /// inference, since a class named `val` is legal plain Java.
    static func importsLombok(_ node: SyntaxNode) -> Bool {
        var root = node
        while let parent = root.parent { root = parent }
        return root.namedChildren.contains { $0.type == "import_declaration" && $0.text.contains("lombok") }
    }
}
