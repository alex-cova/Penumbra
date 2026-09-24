import EditorIntelligence
import Foundation

/// Encapsulates a field (private + accessors + external usage rewrites) and generates getters/setters.
enum JavaEncapsulateField {
    struct FieldContext {
        let symbolID: JavaSymbolID
        let declaringClass: String
        let fieldName: String
        let typeText: String
        let isStatic: Bool
        let isFinal: Bool
        let isPrivate: Bool
        let declaringTypeDecl: SyntaxNode
        let fieldDeclaration: SyntaxNode
        let declarator: SyntaxNode
        let tree: JavaSyntaxTree
        let fileStubs: JavaSourceFileStubs
        let declarationURL: URL
        let declarationSource: String
    }

    // MARK: - Availability

    static func fieldContext(
        source: String,
        url: URL,
        caretUTF16: Int,
        index: JavaIndex,
        environment: JavaReferenceEnvironment
    ) async -> FieldContext? {
        guard !source.isEmpty,
              JavaSyntaxParser().parse(source) != nil else { return nil }
        guard let id = await JavaSymbolIdentity.symbolID(
            at: caretUTF16, in: source, url: url, environment: environment
        ), case .field(let declaringClass, let fieldName) = id else { return nil }

        let declarationURL = await declarationFileURL(declaringClass: declaringClass, index: index, preferred: url)
        let declarationSource = await declarationSource(for: declarationURL, preferred: source, preferredURL: url, environment: environment)
        guard let declarationTree = JavaSyntaxParser().parse(declarationSource),
              let located = locateField(declaringClass: declaringClass, name: fieldName, tree: declarationTree) else { return nil }
        guard located.typeKind != .interfaceKind, located.typeKind != .annotationKind, located.typeKind != .recordKind else {
            return nil
        }
        if isEnumConstant(located: located, declaringClass: declaringClass) { return nil }

        return FieldContext(
            symbolID: id,
            declaringClass: declaringClass,
            fieldName: fieldName,
            typeText: located.typeText,
            isStatic: located.isStatic,
            isFinal: located.isFinal,
            isPrivate: located.isPrivate,
            declaringTypeDecl: located.typeDecl,
            fieldDeclaration: located.fieldDeclaration,
            declarator: located.declarator,
            tree: declarationTree,
            fileStubs: JavaSourceStubBuilder.build(tree: declarationTree, url: declarationURL),
            declarationURL: declarationURL,
            declarationSource: declarationSource
        )
    }

    static func canEncapsulate(_ field: FieldContext) -> Bool {
        true
    }

    static func canGenerateAccessors(_ field: FieldContext) -> Bool {
        let getter = getterName(fieldName: field.fieldName, typeText: field.typeText)
        let setter = setterName(fieldName: field.fieldName)
        let methods = JavaExtractExpression.methodNames(in: field.declaringTypeDecl)
        if field.isFinal {
            return !methods.contains(getter)
        }
        return !methods.contains(getter) || !methods.contains(setter)
    }

    // MARK: - Plans

    static func encapsulatePlan(
        field: FieldContext,
        roots: [URL],
        candidates: any JavaUsageCandidateSource,
        environment: JavaReferenceEnvironment
    ) async -> WorkspaceEditPlan {
        let title = "Encapsulate Field"
        var plan = await generateAccessorsPlan(field: field, title: title, replaceUsages: true, roots: roots, candidates: candidates, environment: environment)
        if plan.blockingError != nil { return plan }

        if !field.isPrivate, let entry = privatizeEntry(for: field) {
            plan.entries.insert(entry, at: 0)
        }
        return plan
    }

    static func generateAccessorsPlan(
        field: FieldContext,
        title: String = "Generate Accessors",
        replaceUsages: Bool = false,
        roots: [URL] = [],
        candidates: (any JavaUsageCandidateSource)? = nil,
        environment: JavaReferenceEnvironment? = nil
    ) async -> WorkspaceEditPlan {
        let getter = getterName(fieldName: field.fieldName, typeText: field.typeText)
        let setter = setterName(fieldName: field.fieldName)
        let methods = JavaExtractExpression.methodNames(in: field.declaringTypeDecl)
        let needsGetter = !methods.contains(getter)
        let needsSetter = !field.isFinal && !methods.contains(setter)
        guard needsGetter || needsSetter else {
            return WorkspaceEditPlan(blockingError: "Getter and setter already exist.", title: title)
        }

        var entries: [WorkspaceEditPlanEntry] = []
        var warnings: [String] = []
        let indent = JavaExtractExpression.leadingIndent(forNode: field.fieldDeclaration, in: field.declarationSource)
        var text = ""
        if needsGetter { text += accessorMethod(field: field, kind: .getter, indent: indent) }
        if needsSetter { text += accessorMethod(field: field, kind: .setter, indent: indent) }
        entries.append(JavaRefactoringText.planEntry(
            url: field.declarationURL,
            byteRange: field.fieldDeclaration.endByte..<field.fieldDeclaration.endByte,
            oldText: "", newText: "\n" + text,
            source: field.declarationSource, description: "Insert accessors"
        ))

        if replaceUsages, let environment, let candidates {
            let usageEntries = await usageReplacementEntries(
                field: field, roots: roots, candidates: candidates, environment: environment, warnings: &warnings
            )
            entries.append(contentsOf: usageEntries)
        }

        return WorkspaceEditPlan(entries: entries, warnings: warnings, title: title)
    }

    // MARK: - Naming

    /// JavaBeans: `getFoo` / `isFoo` for booleans, `setFoo` for mutators.
    static func getterName(fieldName: String, typeText: String) -> String {
        let capitalized = capitalize(fieldName)
        return isBooleanType(typeText) ? "is\(capitalized)" : "get\(capitalized)"
    }

    static func setterName(fieldName: String) -> String {
        "set\(capitalize(fieldName))"
    }

    private static func capitalize(_ name: String) -> String {
        guard let first = name.first else { return name }
        return String(first).uppercased() + name.dropFirst()
    }

    private static func isBooleanType(_ typeText: String) -> Bool {
        let trimmed = typeText.trimmingCharacters(in: .whitespaces)
        return trimmed == "boolean" || trimmed == "Boolean"
    }

    // MARK: - Field location

    private struct LocatedField {
        let typeDecl: SyntaxNode
        let fieldDeclaration: SyntaxNode
        let declarator: SyntaxNode
        let typeText: String
        let typeKind: JavaTypeKind
        let isStatic: Bool
        let isFinal: Bool
        let isPrivate: Bool
    }

    private static let typeDeclarationTypes: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration",
        "record_declaration", "annotation_type_declaration"
    ]

    private static func locateField(declaringClass: String, name: String, tree: JavaSyntaxTree) -> LocatedField? {
        let packageName = tree.rootNode.namedChildren.first { $0.type == "package_declaration" }
            .flatMap { JavaTypeNodeConverter.dottedName($0.namedChildren.first!) } ?? ""
        var stack: [(node: SyntaxNode, qualifiedName: String)] = []
        for node in tree.rootNode.namedChildren where typeDeclarationTypes.contains(node.type) {
            if let nameNode = node.child(byFieldName: "name") {
                let simple = nameNode.text
                let qualified = packageName.isEmpty ? simple : "\(packageName).\(simple)"
                stack.append((node, qualified))
            }
        }
        while let current = stack.popLast() {
            if current.qualifiedName == declaringClass,
               let located = fieldNamed(name, in: current.node) {
                return located
            }
            guard let body = current.node.child(byFieldName: "body") else { continue }
            for member in body.namedChildren where typeDeclarationTypes.contains(member.type) {
                guard let nameNode = member.child(byFieldName: "name") else { continue }
                stack.append((member, "\(current.qualifiedName).\(nameNode.text)"))
            }
        }
        return nil
    }

    private static func fieldNamed(_ name: String, in typeDecl: SyntaxNode) -> LocatedField? {
        guard let body = typeDecl.child(byFieldName: "body") else { return nil }
        let typeKind = JavaExtractExpression.typeKind(of: typeDecl) ?? .classKind
        for member in body.namedChildren where member.type == "field_declaration" {
            for declarator in member.namedChildren(ofType: "variable_declarator") {
                guard declarator.child(byFieldName: "name")?.text == name else { continue }
                let modifiersText = member.namedChildren.first { $0.type == "modifiers" }?.text ?? ""
                let typeText = member.child(byFieldName: "type")?.text ?? "Object"
                return LocatedField(
                    typeDecl: typeDecl,
                    fieldDeclaration: member,
                    declarator: declarator,
                    typeText: typeText,
                    typeKind: typeKind,
                    isStatic: modifiersText.contains("static"),
                    isFinal: modifiersText.contains("final"),
                    isPrivate: modifiersText.contains("private")
                )
            }
        }
        return nil
    }

    private static func isEnumConstant(located: LocatedField, declaringClass: String) -> Bool {
        guard located.typeKind == .enumKind else { return false }
        return located.fieldDeclaration.parent?.type == "enum_body_declarations"
            || located.declarator.parent?.parent?.type == "enum_constant"
    }

    // MARK: - Accessor generation

    private enum AccessorKind { case getter, setter }

    private static func accessorMethod(field: FieldContext, kind: AccessorKind, indent: String) -> String {
        let staticPrefix = field.isStatic ? "static " : ""
        switch kind {
        case .getter:
            let name = getterName(fieldName: field.fieldName, typeText: field.typeText)
            let value = field.isStatic ? field.fieldName : "this.\(field.fieldName)"
            return """
            \(indent)public \(staticPrefix)\(field.typeText) \(name)() {
            \(indent)    return \(value);
            \(indent)}

            """
        case .setter:
            let name = setterName(fieldName: field.fieldName)
            let assignment = field.isStatic ? "\(field.fieldName) = \(field.fieldName);" : "this.\(field.fieldName) = \(field.fieldName);"
            return """
            \(indent)public \(staticPrefix)void \(name)(\(field.typeText) \(field.fieldName)) {
            \(indent)    \(assignment)
            \(indent)}

            """
        }
    }

    // MARK: - Privatize

    private static func privatizeEntry(for field: FieldContext) -> WorkspaceEditPlanEntry? {
        let declaration = field.fieldDeclaration
        if let modifiers = declaration.namedChildren.first { $0.type == "modifiers" } {
            let text = modifiers.text
            if text.contains("private") { return nil }
            var newText = text
            for keyword in ["public", "protected"] {
                newText = newText.replacingOccurrences(of: keyword, with: "").replacingOccurrences(of: "  ", with: " ")
            }
            newText = "private" + (newText.isEmpty ? "" : " ") + newText.trimmingCharacters(in: .whitespaces)
            return JavaRefactoringText.planEntry(
                url: field.declarationURL, byteRange: modifiers.byteRange, oldText: text, newText: newText,
                source: field.declarationSource, description: "Make field private"
            )
        }
        guard let typeNode = declaration.child(byFieldName: "type") else { return nil }
        return JavaRefactoringText.planEntry(
            url: field.declarationURL, byteRange: typeNode.startByte..<typeNode.startByte,
            oldText: "", newText: "private ",
            source: field.declarationSource, description: "Make field private"
        )
    }

    // MARK: - Usage replacement

    /// External usages (outside the declaring type body) are rewritten to accessor calls; usages
    /// inside the declaring type keep direct field access.
    private static func usageReplacementEntries(
        field: FieldContext,
        roots: [URL],
        candidates: any JavaUsageCandidateSource,
        environment: JavaReferenceEnvironment,
        warnings: inout [String]
    ) async -> [WorkspaceEditPlanEntry] {
        let searchRoots = roots.isEmpty ? [field.declarationURL] : roots
        let usages = await JavaUsageSearch.collect(
            field.symbolID, candidates: candidates, roots: searchRoots, environment: environment, includeDeclarations: true
        )
        let getter = getterName(fieldName: field.fieldName, typeText: field.typeText)
        let setter = setterName(fieldName: field.fieldName)
        var entries: [WorkspaceEditPlanEntry] = []
        var skippedCompound = false
        var skippedBare = false

        for usage in usages {
            guard usage.kind != .declaration else { continue }
            let source = await declarationSource(
                for: usage.url, preferred: field.declarationSource, preferredURL: field.declarationURL, environment: environment
            )
            guard let tree = JavaSyntaxParser().parse(source) else { continue }
            let node = tree.node(inByteRange: usage.byteRange)
            guard node.byteRange.overlaps(usage.byteRange) else { continue }
            if isWithinDeclaringType(node: node, declaringTypeDecl: field.declaringTypeDecl) { continue }
            if let entry = replacementEntry(
                usage: usage, node: node, tree: tree, source: source, url: usage.url,
                getter: getter, setter: setter, field: field, warnings: &skippedCompound, skippedBare: &skippedBare
            ) {
                entries.append(entry)
            }
        }
        if skippedCompound {
            warnings.append("Compound assignments (+=, ++) were not rewritten — update them manually.")
        }
        if skippedBare {
            warnings.append("Some bare-name field references were not rewritten — qualify them or update manually.")
        }
        return entries
    }

    private static func isWithinDeclaringType(node: SyntaxNode, declaringTypeDecl: SyntaxNode) -> Bool {
        guard let body = declaringTypeDecl.child(byFieldName: "body") else { return false }
        return body.startByte <= node.startByte && node.endByte <= body.endByte
    }

    private static func replacementEntry(
        usage: JavaUsage,
        node: SyntaxNode,
        tree: JavaSyntaxTree,
        source: String,
        url: URL,
        getter: String,
        setter: String,
        field: FieldContext,
        warnings: inout Bool,
        skippedBare: inout Bool
    ) -> WorkspaceEditPlanEntry? {
        let token = nameToken(for: node) ?? node
        guard token.text == field.fieldName else { return nil }
        guard let reference = JavaReferenceClassifier.classify(token: token) else { return nil }

        switch reference {
        case .fieldAccess(let access):
            guard let object = access.child(byFieldName: "object") else { return nil }
            let receiver = tree.text(in: object.byteRange)
            let replacement: String
            let range: Range<Int>
            if usage.kind == .write {
                guard let assignment = assignmentReplacing(access: access, tree: tree, receiver: receiver, setter: setter) else {
                    warnings = true
                    return nil
                }
                replacement = assignment.text
                range = assignment.range
            } else {
                replacement = "\(receiver).\(getter)()"
                range = access.byteRange
            }
            return WorkspaceEditPlanEntry(
                url: url.standardizedFileURL,
                range: JavaRefactoringText.textRange(for: range, in: source),
                oldText: tree.text(in: range),
                newText: replacement,
                lineText: JavaRefactoringText.lineText(forByteRange: range, in: source),
                description: usage.kind == .write ? "Replace write" : "Replace read",
                isAmbiguous: usage.confidence == .ambiguous
            )
        case .bareName where field.isStatic:
            if usage.kind == .write {
                skippedBare = true
                return nil
            }
            skippedBare = true
            return nil
        default:
            return nil
        }
    }

    private static func assignmentReplacing(
        access: SyntaxNode, tree: JavaSyntaxTree, receiver: String, setter: String
    ) -> (text: String, range: Range<Int>)? {
        guard let parent = access.parent, parent.type == "assignment_expression",
              parent.child(byFieldName: "left")?.byteRange == access.byteRange,
              let right = parent.child(byFieldName: "right") else { return nil }
        let value = tree.text(in: right.byteRange)
        return ("\(receiver).\(setter)(\(value))", parent.byteRange)
    }

    private static func nameToken(for node: SyntaxNode) -> SyntaxNode? {
        if node.type == "identifier" || node.type == "type_identifier" { return node }
        return nil
    }

    // MARK: - Source loading

    private static func declarationFileURL(declaringClass: String, index: JavaIndex, preferred: URL) async -> URL {
        if let stub = await index.classStub(qualifiedName: declaringClass), case .source(let file, _) = stub.origin {
            return file.standardizedFileURL
        }
        return preferred.standardizedFileURL
    }

    private static func declarationSource(
        for url: URL,
        preferred: String,
        preferredURL: URL,
        environment: JavaReferenceEnvironment
    ) async -> String {
        if url.standardizedFileURL == preferredURL.standardizedFileURL, !preferred.isEmpty { return preferred }
        if let openBuffer = environment.openBuffer, let buffer = await openBuffer(url), !buffer.isEmpty { return buffer }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
