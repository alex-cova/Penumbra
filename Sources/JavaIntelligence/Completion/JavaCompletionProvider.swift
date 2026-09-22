import EditorIntelligence
import Foundation

/// The `EditorIntelligence.CompletionProvider` that turns everything the rest of `JavaIntelligence`
/// builds (the index, type resolution, member lookup, expression typing) into actual completion
/// items for a Java document. Active only for `languageIdentifier == "java"`.
///
/// Two completion contexts are distinguished by one check -- is the byte immediately before the
/// completion prefix a `.` -- since that's the only trigger character Java member access uses:
/// - **Member access** (`foo.<prefix>`): types the receiver via ``JavaExpressionTyper`` and offers
///   its members via ``JavaMemberLookup``.
/// - **General/statement position** (anywhere else): locals in scope, implicit-`this`
///   members, class names by prefix from the index, and a small curated keyword list.
///
/// Known simplifications for this first version (documented, not silently missing): completion
/// items don't carry a `detail` signature string (folded into `documentation` instead, since the
/// shared `EditorIntelligence.CompletionItem` doesn't have that field yet) and there's no
/// auto-import insertion for an unqualified class name completed from outside its package --
/// accepting the completion inserts the simple name only, same as accepting a name that needs no
/// import. Both are natural follow-ups once `CompletionItem` grows the richer fields the
/// hand-off plan describes (`detail`, `additionalEdits`, ...); deferred here to avoid changing
/// shared, every-language infrastructure without dedicated review.
public actor JavaCompletionProvider: CompletionProvider {
    public let name = "Java"
    private let index: JavaIndex
    private let classNameCompletionLimit: Int

    public init(index: JavaIndex, classNameCompletionLimit: Int = 100) {
        self.index = index
        self.classNameCompletionLimit = classNameCompletionLimit
    }

    public func provide(context: CompletionContext) async -> [CompletionItem] {
        guard context.document.languageIdentifier == "java" else { return [] }
        guard !context.document.contentSnapshot.isElided else { return [] }
        let text = context.document.text
        guard let tree = JavaSyntaxParser().parse(text) else { return [] }

        let bytes = Array(text.utf8)
        let prefixStartByte = Self.utf8ByteOffset(forUTF16Offset: context.range.start.utf16Offset, in: text)
        let cursorByte = Self.utf8ByteOffset(forUTF16Offset: context.cursor.position.utf16Offset, in: text)

        let fileURL = context.document.url ?? URL(fileURLWithPath: "/unsaved/\(context.document.id).java")
        let fileStubs = JavaSourceStubBuilder.build(source: text, url: fileURL)
        let enclosing = Self.enclosingTypeContext(in: tree, atByteOffset: min(prefixStartByte, cursorByte))
        let resolutionContext = JavaResolutionContext(
            packageName: fileStubs.packageName,
            imports: fileStubs.imports,
            enclosingTypeQualifiedNames: enclosing.qualifiedNames,
            typeParameterNames: enclosing.typeParameterNames
        )

        if prefixStartByte > 0, bytes[prefixStartByte - 1] == UInt8(ascii: ".") {
            return await memberAccessItems(
                dotOffset: prefixStartByte - 1, prefix: context.prefix, source: text, tree: tree,
                range: context.range, resolutionContext: resolutionContext
            )
        }
        return await generalItems(
            prefix: context.prefix, byteOffset: cursorByte, tree: tree, range: context.range, resolutionContext: resolutionContext
        )
    }

    // MARK: - Member access

    private func memberAccessItems(
        dotOffset: Int, prefix: String, source: String, tree: JavaSyntaxTree, range: EditorIntelligence.TextRange, resolutionContext: JavaResolutionContext
    ) async -> [CompletionItem] {
        guard let receiver = await JavaExpressionTyper.receiverInfo(
            source: source, realTree: tree, dotOffset: dotOffset, context: resolutionContext, index: index
        ) else {
            return []
        }
        let mode: JavaMemberLookupMode = receiver.isTypeReference ? .staticOnly : .instance
        let members = await JavaMemberLookup.members(of: receiver.type, mode: mode, context: resolutionContext, index: index)
        let lowerPrefix = prefix.lowercased()
        return members.filter { prefix.isEmpty || $0.name.lowercased().hasPrefix(lowerPrefix) }.map { member in
            switch member {
            case .field(let field, let declaringClass):
                return CompletionItem(
                    label: field.name, insertText: field.name, kind: .property, range: range, source: name,
                    documentation: fieldDocumentation(field, declaringClass: declaringClass)
                )
            case .method(let method, let declaringClass):
                return CompletionItem(
                    label: method.name, insertText: "\(method.name)()", kind: .method, range: range, source: name,
                    documentation: methodDocumentation(method, declaringClass: declaringClass)
                )
            }
        }
    }

    // MARK: - General / statement position

    private func generalItems(
        prefix: String, byteOffset: Int, tree: JavaSyntaxTree, range: EditorIntelligence.TextRange, resolutionContext: JavaResolutionContext
    ) async -> [CompletionItem] {
        var items: [CompletionItem] = []

        let locals = JavaLocalScope.locals(in: tree, atByteOffset: byteOffset)
        for local in locals where prefix.isEmpty || local.name.lowercased().hasPrefix(prefix.lowercased()) {
            items.append(CompletionItem(label: local.name, insertText: local.name, kind: .variable, range: range, source: name))
        }

        if let enclosingType = resolutionContext.enclosingTypeQualifiedNames.first {
            let selfType = JavaTypeRef.classType(qualifiedName: enclosingType, arguments: [], outer: nil)
            let members = await JavaMemberLookup.members(of: selfType, mode: .instance, context: resolutionContext, index: index)
            for member in members {
                switch member {
                case .field(let field, let declaringClass):
                    guard prefix.isEmpty || field.name.lowercased().hasPrefix(prefix.lowercased()) else { continue }
                    items.append(CompletionItem(
                        label: field.name, insertText: field.name, kind: .property, range: range, source: name,
                        documentation: fieldDocumentation(field, declaringClass: declaringClass)
                    ))
                case .method(let method, let declaringClass):
                    guard prefix.isEmpty || method.name.lowercased().hasPrefix(prefix.lowercased()) else { continue }
                    items.append(CompletionItem(
                        label: method.name, insertText: "\(method.name)()", kind: .method, range: range, source: name,
                        documentation: methodDocumentation(method, declaringClass: declaringClass)
                    ))
                }
            }
        }

        if !prefix.isEmpty {
            let classes = await index.classes(simpleNamePrefix: prefix, limit: classNameCompletionLimit)
            for stub in classes {
                items.append(CompletionItem(
                    label: stub.simpleName, insertText: stub.simpleName, kind: .type, range: range, source: name,
                    documentation: stub.packageName.isEmpty ? nil : stub.packageName
                ))
            }
            for keyword in Self.keywords where keyword.hasPrefix(prefix) {
                items.append(CompletionItem(label: keyword, insertText: keyword, kind: .keyword, range: range, source: name))
            }
        }

        return items
    }

    // MARK: - Documentation strings

    /// A short one-line signature, since `CompletionItem` has no dedicated `detail` field yet (see
    /// the type's doc comment).
    private func fieldDocumentation(_ field: JavaFieldStub, declaringClass: String) -> String {
        "\(field.type.simpleDisplayName) \(field.name) -- \(declaringClass)"
    }

    private func methodDocumentation(_ method: JavaMethodStub, declaringClass: String) -> String {
        "\(method.returnType.simpleDisplayName) \(method.name)\(method.parameterListDisplay) -- \(declaringClass)"
    }

    // MARK: - Enclosing type / offset helpers

    struct EnclosingTypeContext {
        let qualifiedNames: [String]
        let typeParameterNames: Set<String>
    }

    /// Walks up from the node at `byteOffset` collecting enclosing type declarations (innermost
    /// first) by node type -- best-effort, like `JavaLocalScope`: a trailing bare `.` on anything
    /// beyond a simple identifier can collapse the whole declaration into one `ERROR` node with no
    /// recoverable class name (see `JavaReceiverScanner`'s doc comment), in which case this simply
    /// returns empty and callers fall back to no enclosing-type context for that one request --
    /// self-correcting on the very next keystroke once the tree is well-formed again.
    static func enclosingTypeContext(in tree: JavaSyntaxTree, atByteOffset byteOffset: Int) -> EnclosingTypeContext {
        let typeDeclarationTypes: Set<String> = [
            "class_declaration", "interface_declaration", "enum_declaration", "record_declaration", "annotation_type_declaration"
        ]
        var simpleNames: [String] = [] // innermost first
        var typeParameterNames: Set<String> = []
        var current: SyntaxNode? = tree.node(atByteOffset: byteOffset)
        while let node = current {
            if typeDeclarationTypes.contains(node.type), let nameNode = node.child(byFieldName: "name") {
                simpleNames.append(nameNode.text)
                if let typeParams = node.child(byFieldName: "type_parameters") {
                    for parameter in typeParams.namedChildren(ofType: "type_parameter") {
                        if let paramName = parameter.namedChild(at: 0) {
                            typeParameterNames.insert(paramName.text)
                        }
                    }
                }
            }
            current = node.parent
        }
        guard !simpleNames.isEmpty else { return EnclosingTypeContext(qualifiedNames: [], typeParameterNames: []) }
        // simpleNames is innermost-first; build qualified names by joining from outermost inward.
        var qualifiedNames: [String] = []
        var prefix = ""
        for simpleName in simpleNames.reversed() {
            prefix = prefix.isEmpty ? simpleName : "\(prefix).\(simpleName)"
            qualifiedNames.append(prefix)
        }
        qualifiedNames.reverse() // innermost first, matching JavaResolutionContext's convention
        return EnclosingTypeContext(qualifiedNames: qualifiedNames, typeParameterNames: typeParameterNames)
    }

    /// `Document.cursor`/`range` positions are UTF-16 offsets (matching how the rest of Penumbra/
    /// EIP addresses text); everything in `JavaIntelligence` works in UTF-8 byte offsets (matching
    /// tree-sitter). This converts between the two for one position.
    static func utf8ByteOffset(forUTF16Offset utf16Offset: Int, in text: String) -> Int {
        guard let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset, limitedBy: text.utf16.endIndex),
              let stringIndex = utf16Index.samePosition(in: text) else {
            return text.utf8.count
        }
        return text.utf8.distance(from: text.utf8.startIndex, to: stringIndex.samePosition(in: text.utf8)!)
    }

    /// A small, high-value subset of Java keywords -- statement/declaration starters and common
    /// modifiers -- rather than the full reserved-word list, since most of the rest (`goto`,
    /// `strictfp`, ...) are rarely what a user wants suggested.
    static let keywords: [String] = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "continue",
        "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for",
        "if", "implements", "import", "instanceof", "int", "interface", "long", "new", "null",
        "package", "private", "protected", "public", "return", "short", "static", "super", "switch",
        "synchronized", "this", "throw", "throws", "true", "false", "try", "void", "volatile", "while"
    ]
}
