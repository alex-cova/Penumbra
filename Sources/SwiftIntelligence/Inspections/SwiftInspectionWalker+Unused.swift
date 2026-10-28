import Foundation
import SwiftSyntax

// Unused code: a private declaration that nothing in its file mentions.
extension SwiftInspectionWalker {
    /// Names that are used without being written: a protocol's requirement, a synthesized conformance, a framework
    /// calling by name.
    static let implicitlyUsedNames: Set<String> = [
        "body", "description", "debugDescription", "hash", "hashValue", "encode", "init", "deinit", "main", "CodingKeys",
        "makeBody", "makeUIView", "updateUIView", "makeNSView", "updateNSView", "makeUIViewController", "updateUIViewController",
        "makeNSViewController", "updateNSViewController", "makeCoordinator", "previews", "preview", "defaultValue", "wrappedValue",
        "projectedValue", "callAsFunction", "next", "makeIterator", "startIndex", "endIndex", "count", "isEmpty", "subscript",
    ]

    static func countIdentifiers(in tree: SourceFileSyntax) -> [String: Int] {
        var counts: [String: Int] = [:]
        for token in tree.tokens(viewMode: .sourceAccurate) {
            guard case .identifier(let text) = token.tokenKind else { continue }
            counts[Identifier(token)?.name ?? text, default: 0] += 1
        }
        return counts
    }

    func checkUnusedPrivate(function node: FunctionDeclSyntax) {
        guard isOn(.unusedPrivateMember), node.attributes.isEmpty, isPrivateScoped(node.modifiers), isUnoverriding(node.modifiers),
              declaredAtTypeOrFileLevel(node) else { return }
        report(unusedName: node.name, deleting: Syntax(node))
    }

    func checkUnusedPrivate(variable node: VariableDeclSyntax) {
        guard isOn(.unusedPrivateMember), node.attributes.isEmpty, isPrivateScoped(node.modifiers), isUnoverriding(node.modifiers),
              declaredAtTypeOrFileLevel(node) else { return }
        // Only a declaration that binds one name can go as a whole; the others each keep their report but no fix.
        let whole = node.bindings.count == 1 ? Syntax(node) : nil
        for binding in node.bindings {
            // A pattern that binds several names, or an accessor block that makes it a protocol witness, is left alone.
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            report(unusedName: pattern.identifier, deleting: whole)
        }
    }

    func checkUnusedPrivate(type node: some SyntaxProtocol, name: TokenSyntax, modifiers: DeclModifierListSyntax, attributes: AttributeListSyntax) {
        guard isOn(.unusedPrivateMember), attributes.isEmpty, isPrivateScoped(modifiers), declaredAtTypeOrFileLevel(node) else { return }
        report(unusedName: name, deleting: Syntax(node))
    }

    private func report(unusedName token: TokenSyntax, deleting node: Syntax? = nil) {
        let name = Identifier(token)?.name ?? token.text
        guard !Self.implicitlyUsedNames.contains(name), name != "_", identifierCounts[name] == 1 else { return }
        // The fix deletes the declaration's whole line; a declaration that shares its line with other
        // code keeps the report but no fix. File-local and single-file by construction, but still a
        // decision, so it never runs from Fix all.
        let fixes: [SwiftInspectionFix]
        if let node, let line = SwiftInspectionFix.lineDeleting(bytes(node), in: utf8) {
            fixes = [SwiftInspectionFix(
                title: "Safe delete '\(name)'", edits: [.init(bytes: line, replacement: "")], isBatchable: false
            )]
        } else {
            fixes = []
        }
        report(.unusedPrivateMember, "'\(name)' is private and nothing else in this file mentions it.", at: token, fixes: fixes)
    }

    private func isPrivateScoped(_ modifiers: DeclModifierListSyntax) -> Bool { SwiftUnusedCode.isPrivateScoped(modifiers) }
    private func isUnoverriding(_ modifiers: DeclModifierListSyntax) -> Bool { SwiftUnusedCode.isUnoverriding(modifiers) }
    private func declaredAtTypeOrFileLevel(_ node: some SyntaxProtocol) -> Bool { SwiftUnusedCode.declaredAtTypeOrFileLevel(node) }
}

/// Questions about a declaration that both unused-code rules ask.
enum SwiftUnusedCode {
    /// Attributes on an enclosing type that do not make its members reachable in ways the file does not show.
    static let harmlessTypeAttributes: Set<String> = [
        "MainActor", "available", "Sendable", "preconcurrency", "frozen", "usableFromInline", "inlinable", "unchecked",
    ]


    /// `private` or `fileprivate` for the declaration itself (not only its setter).
    static func isPrivateScoped(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { modifier in
            modifier.detail == nil && (modifier.name.tokenKind == .keyword(.private) || modifier.name.tokenKind == .keyword(.fileprivate))
        }
    }

    /// Declared with no access keyword of its own: internal, or what its type gives it.
    static func hasNoAccessModifier(_ modifiers: DeclModifierListSyntax) -> Bool {
        let access: Set<Keyword> = [.private, .fileprivate, .internal, .public, .open, .package]
        return !modifiers.contains { modifier in
            if case .keyword(let keyword) = modifier.name.tokenKind { return access.contains(keyword) && modifier.detail == nil }
            return false
        }
    }

    static func isPublicOrOpen(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.tokenKind == .keyword(.public) || $0.name.tokenKind == .keyword(.open) }
    }

    /// Whether an enclosing type or extension lists a protocol or superclass: its members may be called by the
    /// framework, the compiler or the protocol without the name being written.
    static func isMemberOfConformingType(_ node: some SyntaxProtocol) -> Bool {
        var current: Syntax? = node.parent
        while let candidate = current {
            if let decl = candidate.as(StructDeclSyntax.self), decl.inheritanceClause != nil { return true }
            if let decl = candidate.as(ClassDeclSyntax.self), decl.inheritanceClause != nil { return true }
            if let decl = candidate.as(EnumDeclSyntax.self), decl.inheritanceClause != nil { return true }
            if let decl = candidate.as(ActorDeclSyntax.self), decl.inheritanceClause != nil { return true }
            if let decl = candidate.as(ExtensionDeclSyntax.self), decl.inheritanceClause != nil { return true }
            current = candidate.parent
        }
        return false
    }

    static func isUnoverriding(_ modifiers: DeclModifierListSyntax) -> Bool {
        !modifiers.contains { $0.name.tokenKind == .keyword(.override) || $0.name.tokenKind == .keyword(.dynamic) }
    }

    /// A member of a type or extension, or a top-level declaration, whose enclosing types carry no attribute that could
    /// reach it from a macro or the runtime.
    static func declaredAtTypeOrFileLevel(_ node: some SyntaxProtocol) -> Bool {
        guard let parent = node.parent else { return false }
        let atFile = parent.is(CodeBlockItemSyntax.self) && parent.parent?.parent?.is(SourceFileSyntax.self) == true
        let inMembers = parent.is(MemberBlockItemSyntax.self)
        guard atFile || inMembers else { return false }
        var current: Syntax? = parent
        while let candidate = current {
            let attributes: AttributeListSyntax?
            if let decl = candidate.as(StructDeclSyntax.self) { attributes = decl.attributes }
            else if let decl = candidate.as(ClassDeclSyntax.self) { attributes = decl.attributes }
            else if let decl = candidate.as(EnumDeclSyntax.self) { attributes = decl.attributes }
            else if let decl = candidate.as(ActorDeclSyntax.self) { attributes = decl.attributes }
            else if let decl = candidate.as(ExtensionDeclSyntax.self) { attributes = decl.attributes }
            else if candidate.is(ProtocolDeclSyntax.self) { return false }
            else { attributes = nil }
            if let attributes {
                for element in attributes {
                    guard let attribute = element.as(AttributeSyntax.self),
                          let name = attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text,
                          harmlessTypeAttributes.contains(name) else { return false }
                }
            }
            current = candidate.parent
        }
        return true
    }
}