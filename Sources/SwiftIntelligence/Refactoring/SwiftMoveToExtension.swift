import Foundation
import SwiftSyntax

/// Move the member at the caret out of its type into a new `extension` of that type, right after the type.
///
/// Only what an extension can hold moves: methods, computed properties, subscripts, nested types, type aliases,
/// static stored properties (not in a generic type) and, in a struct or enum, initializers. A stored property, an
/// `override`, a `required` or designated class initializer, an enum case and a `deinit` stay where they are.
public enum SwiftMoveToExtension {
    public static func isAvailable(in text: String, caret: Int) -> Bool {
        if case .success = edits(in: text, caret: caret) { return true }
        return false
    }

    public static func edits(in text: String, caret: Int) -> SwiftRefactoringResult {
        guard let file = SwiftRefactoringFile.load(text) else {
            return .failure(.init("The file has syntax errors; fix them before refactoring."))
        }
        guard let member = member(at: caret, file: file) else {
            return .failure(.init("Place the caret on a member of a struct, class, enum or actor."))
        }
        guard let owner = member.parent?.parent?.parent else {
            return .failure(.init("The member is not inside a type."))
        }
        guard let ownerInfo = Owner(owner) else {
            return .failure(.init("Only a member of a struct, class, enum or actor can move to an extension."))
        }
        if let reason = cannotMove(member.decl, owner: ownerInfo) { return .failure(.init(reason)) }
        guard let path = typePath(of: owner), let top = outermostType(of: owner) else {
            return .failure(.init("The type is declared inside a function or an extension."))
        }

        let unit = unitIndent(owner: owner, member: member, file: file)
        let memberRange = member.position.utf8Offset ..< member.endPosition.utf8Offset
        let memberStart = SwiftRefactoringFile.trimmed(member)
        let memberIndent = file.indentation(before: memberStart.lowerBound) ?? ""
        // The member with its doc comment, without the blank line that may precede it.
        let leading = file.string(memberRange.lowerBound ..< memberStart.lowerBound)
        let comment = leading.drop { $0 == "\n" || $0 == "\r" }
        let declaration = file.string(memberStart)
        let body = reindented(String(comment) + declaration, from: memberIndent, to: unit, firstLineAlreadyIndented: true)

        let topEnd = SwiftRefactoringFile.trimmed(top).upperBound
        let insertion = "\n\nextension \(path) {\n\(unit)\(body.drop { $0 == " " || $0 == "\t" })\n}"
        // Remove the member, and the line break that led to it, so the type has no gap left.
        return .success([
            SwiftTextEdit(bytes: memberRange, replacement: ""),
            SwiftTextEdit(bytes: topEnd ..< topEnd, replacement: insertion),
        ])
    }

    // MARK: - Finding the member

    private static func member(at caret: Int, file: SwiftRefactoringFile) -> MemberBlockItemSyntax? {
        guard let token = file.tree.token(at: AbsolutePosition(utf8Offset: min(max(caret, 0), max(file.utf8.count - 1, 0)))) else { return nil }
        var node: Syntax? = Syntax(token)
        var result: MemberBlockItemSyntax?
        while let current = node {
            if let item = current.as(MemberBlockItemSyntax.self) {
                result = item
                // Keep climbing: a nested type's members are items too, and the caret may be on the nested type's header.
                break
            }
            node = current.parent
        }
        guard let item = result else { return nil }
        // On the member's first line (its header), not anywhere in its body: the menu would offer a move at every line.
        let start = SwiftRefactoringFile.trimmed(item).lowerBound
        var lineEnd = start
        while lineEnd < file.utf8.count, file.utf8[lineEnd] != 0x0A { lineEnd += 1 }
        return caret >= start && caret <= lineEnd ? item : nil
    }

    private struct Owner {
        let isClass: Bool
        let isStruct: Bool
        let isGeneric: Bool
        /// How many initializers the type's own body declares.
        let initializerCount: Int

        init?(_ node: Syntax) {
            func count(_ block: MemberBlockSyntax) -> Int { block.members.filter { $0.decl.is(InitializerDeclSyntax.self) }.count }
            if let decl = node.as(StructDeclSyntax.self) {
                isClass = false; isStruct = true; isGeneric = decl.genericParameterClause != nil; initializerCount = count(decl.memberBlock)
            } else if let decl = node.as(ClassDeclSyntax.self) {
                isClass = true; isStruct = false; isGeneric = decl.genericParameterClause != nil; initializerCount = count(decl.memberBlock)
            } else if let decl = node.as(EnumDeclSyntax.self) {
                isClass = false; isStruct = false; isGeneric = decl.genericParameterClause != nil; initializerCount = count(decl.memberBlock)
            } else if let decl = node.as(ActorDeclSyntax.self) {
                isClass = true; isStruct = false; isGeneric = decl.genericParameterClause != nil; initializerCount = count(decl.memberBlock)
            } else { return nil }
        }
    }

    private static func cannotMove(_ decl: DeclSyntax, owner: Owner) -> String? {
        func modifiers(_ list: DeclModifierListSyntax) -> Set<Keyword> {
            Set(list.compactMap { modifier -> Keyword? in
                if case .keyword(let keyword) = modifier.name.tokenKind { return keyword }
                return nil
            })
        }
        if decl.is(EnumCaseDeclSyntax.self) { return "An enum case cannot be declared in an extension." }
        if decl.is(DeinitializerDeclSyntax.self) { return "A `deinit` has to stay in the type." }
        if decl.is(IfConfigDeclSyntax.self) || decl.is(MacroExpansionDeclSyntax.self) { return "Conditional compilation and macros stay where they are." }
        if let variable = decl.as(VariableDeclSyntax.self) {
            let words = modifiers(variable.modifiers)
            if words.contains(.override) { return "An override in an extension must be `@objc`." }
            if words.contains(.lazy) { return "A `lazy` property is stored." }
            for binding in variable.bindings {
                let computed = binding.accessorBlock.map { block in
                    switch block.accessors {
                    case .getter: true
                    case .accessors(let list): list.contains { $0.accessorSpecifier.tokenKind == .keyword(.get) || $0.accessorSpecifier.tokenKind == .keyword(.set) }
                    }
                } ?? false
                if computed { continue }
                guard words.contains(.static) || words.contains(.class) else { return "A stored property cannot be declared in an extension." }
                if owner.isGeneric { return "A static stored property cannot be declared in an extension of a generic type." }
            }
            return nil
        }
        if let function = decl.as(FunctionDeclSyntax.self) {
            let words = modifiers(function.modifiers)
            if words.contains(.override) { return "An override in an extension must be `@objc`." }
            if words.contains(.required) { return "A `required` member has to stay in the type." }
            return nil
        }
        if let initializer = decl.as(InitializerDeclSyntax.self) {
            let words = modifiers(initializer.modifiers)
            if owner.isClass, !words.contains(.convenience) { return "Only a `convenience` initializer can be in an extension of a class." }
            if words.contains(.required) || words.contains(.override) { return "A `required` or overriding initializer has to stay in the type." }
            // A struct with an initializer in its body has no memberwise one; with none left there it would come back.
            if owner.isStruct, owner.initializerCount <= 1 {
                return "This is the struct's only initializer in its body: moving it out brings the synthesized memberwise initializer back, which can clash with it."
            }
            return nil
        }
        if let subscriptDecl = decl.as(SubscriptDeclSyntax.self) {
            return modifiers(subscriptDecl.modifiers).contains(.override) ? "An override in an extension must be `@objc`." : nil
        }
        if decl.is(StructDeclSyntax.self) || decl.is(ClassDeclSyntax.self) || decl.is(EnumDeclSyntax.self)
            || decl.is(ActorDeclSyntax.self) || decl.is(TypeAliasDeclSyntax.self) {
            return nil
        }
        return "This kind of member cannot be moved."
    }

    // MARK: - Where it goes

    /// `Outer.Inner` for a type nested in types; nil when a function or an extension is in the way.
    private static func typePath(of owner: Syntax) -> String? {
        var names: [String] = []
        var node: Syntax? = owner
        while let current = node {
            if let named = current.asProtocol(NamedDeclSyntax.self),
               current.is(StructDeclSyntax.self) || current.is(ClassDeclSyntax.self) || current.is(EnumDeclSyntax.self) || current.is(ActorDeclSyntax.self) {
                names.insert(named.name.text, at: 0)
            } else if current.is(ExtensionDeclSyntax.self) || current.is(FunctionDeclSyntax.self) || current.is(ProtocolDeclSyntax.self)
                        || current.is(IfConfigClauseSyntax.self) || current.is(InitializerDeclSyntax.self) || current.is(AccessorDeclSyntax.self)
                        || current.is(ClosureExprSyntax.self) {
                return nil
            }
            node = current.parent
        }
        return names.isEmpty ? nil : names.joined(separator: ".")
    }

    /// The top-level declaration around `owner`: the extension goes after it.
    private static func outermostType(of owner: Syntax) -> Syntax? {
        var top = owner
        var node: Syntax? = owner.parent
        while let current = node {
            if current.is(StructDeclSyntax.self) || current.is(ClassDeclSyntax.self) || current.is(EnumDeclSyntax.self) || current.is(ActorDeclSyntax.self) {
                top = current
            }
            node = current.parent
        }
        // It must sit directly in the file, not in `#if`.
        return top.parent?.parent?.is(CodeBlockItemListSyntax.self) == true || top.parent?.is(CodeBlockItemSyntax.self) == true ? top : nil
    }

    private static func unitIndent(owner: Syntax, member: MemberBlockItemSyntax, file: SwiftRefactoringFile) -> String {
        let ownerIndent = file.indentation(before: SwiftRefactoringFile.trimmed(owner).lowerBound) ?? ""
        let memberIndent = file.indentation(before: SwiftRefactoringFile.trimmed(member).lowerBound) ?? ""
        if memberIndent.hasPrefix(ownerIndent), memberIndent.count > ownerIndent.count {
            return String(memberIndent.dropFirst(ownerIndent.count))
        }
        return "    "
    }

    /// `text` re-indented so that lines indented by `old` are indented by `new`.
    private static func reindented(_ text: String, from old: String, to new: String, firstLineAlreadyIndented: Bool) -> String {
        var lines = text.components(separatedBy: "\n")
        for index in lines.indices {
            if index == 0 {
                lines[index] = new + lines[index]
            } else if lines[index].hasPrefix(old) {
                lines[index] = new + lines[index].dropFirst(old.count)
            }
        }
        return lines.joined(separator: "\n")
    }
}
