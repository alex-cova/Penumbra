import Foundation

/// What an identifier occurrence is doing, syntactically. The usage search narrows candidate
/// files by role before resolving anything: a file that mentions `foo` only as a type cannot
/// contain a call of method `foo`, so it is never parsed. Roles mirror
/// ``JavaReferenceClassifier/classify(token:)`` exactly (plus the method-reference qualifier,
/// which the classifier never sees): anything the classifier can turn into a usage has a role,
/// and the target-to-role mapping in ``JavaSymbolID/candidateRoles`` is the set of references
/// that can match each target.
public enum JavaIdentifierRole: UInt8, Sendable, Hashable, CaseIterable {
    /// A `method_invocation` name.
    case call = 1
    /// A `field_access` field or a `method_reference` name (`String::length`).
    case member = 2
    /// A name in type position (a `.type` or `.constructor` reference, or the qualifier of a
    /// method reference, which names the functional type or constructor owner).
    case typeName = 4
    /// A declared type, method, field, enum constant or record component.
    case declared = 8
    /// A segment of an import declaration.
    case imported = 16
    /// Any other identifier in code: bare names, case labels, qualifiers. The never-exclude
    /// bucket for targets a bare name can resolve to.
    case plain = 32
}

/// A set of ``JavaIdentifierRole``s, stored as one byte per (file, identifier) posting.
public struct JavaIdentifierRoles: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let call = JavaIdentifierRoles(rawValue: JavaIdentifierRole.call.rawValue)
    public static let member = JavaIdentifierRoles(rawValue: JavaIdentifierRole.member.rawValue)
    public static let typeName = JavaIdentifierRoles(rawValue: JavaIdentifierRole.typeName.rawValue)
    public static let declared = JavaIdentifierRoles(rawValue: JavaIdentifierRole.declared.rawValue)
    public static let imported = JavaIdentifierRoles(rawValue: JavaIdentifierRole.imported.rawValue)
    public static let plain = JavaIdentifierRoles(rawValue: JavaIdentifierRole.plain.rawValue)

    /// No filtering: every file is a candidate, as before roles existed.
    public static let all: JavaIdentifierRoles = [.call, .member, .typeName, .declared, .imported, .plain]
}

/// Reads the roles of every identifier occurrence in a parsed file. Parse trees are walked once;
/// comments and string literals contain no identifier nodes, so like the name index a mention in
/// either never narrows anything in. `this` and `super` are skipped: constructor delegation
/// through them carries no name, and files that only delegate are already missed by the
/// name-gated candidate search, so roles change nothing there.
public enum JavaRoleExtractor {
    /// Identifier text to the union of its roles in `tree`. A file that does not parse yields an
    /// empty map, and the role index records every name it can still tokenize with all roles, so
    /// an unparseable file is never narrowed out.
    public static func roles(in tree: JavaSyntaxTree) -> [String: JavaIdentifierRoles] {
        var result: [String: JavaIdentifierRoles] = [:]
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            let type = node.type
            if type == "identifier" || type == "type_identifier" {
                if let role = role(of: node) {
                    result[node.text, default: []].formUnion(role)
                }
            }
            stack.append(contentsOf: node.children)
        }
        return result
    }

    private static func role(of token: SyntaxNode) -> JavaIdentifierRoles? {
        // `s::length` selects a member of the qualifier, which itself can bind a field (a bound
        // receiver) or a type, so it carries both roles; the union only ever keeps files the
        // classifier could also match, never fewer. The selected name resolves like a member use.
        if token.type == "identifier", let parent = token.parent, parent.type == "method_reference",
           parent.namedChildCount > 1 {
            if parent.namedChildren.last?.byteRange == token.byteRange { return .member }
            var roles: JavaIdentifierRoles = [.typeName, .plain]
            if let qualified = JavaReferenceClassifier.classify(token: token),
               let extra = role(of: qualified) {
                roles.formUnion(extra)
            }
            return roles
        }
        guard let reference = JavaReferenceClassifier.classify(token: token) else { return nil }
        return role(of: reference)
    }

    private static func role(of reference: JavaReference) -> JavaIdentifierRoles? {
        switch reference {
        case .declaration:
            return .declared
        case .methodCall:
            return .call
        case .fieldAccess:
            return .member
        case .constructor:
            return .typeName
        case .import:
            return .imported
        case .type:
            return .typeName
        case .bareName:
            return .plain
        case .keywordThis, .keywordSuper, .explicitConstructor:
            return nil
        }
    }
}

extension JavaSymbolID {
    /// The roles whose occurrences can resolve to this symbol (see ``JavaRoleExtractor``). A file
    /// is worth resolving only when the target's name occurs in one of these roles there; every
    /// other occurrence classifies to a reference that can never match (a method is never found
    /// through a type name, a field never through a call). Locals are file-scoped, so roles never
    /// narrow them; the empty set would filter everything out, hence all roles.
    public var candidateRoles: JavaIdentifierRoles {
        switch self {
        case .method:
            // Calls, `::` references, the declaration itself, and (static) imports.
            return [.call, .member, .declared, .imported]
        case .constructor:
            // `new Foo`, constructor declarations, and imports. `this(...)`/`super(...)`
            // delegation carries no name and stays name-gated as before.
            return [.typeName, .declared, .imported]
        case .field:
            // Qualified accesses, bare reads and writes, declarations, and (static) imports.
            return [.member, .plain, .declared, .imported]
        case .type:
            // Type positions, dotted paths through field accesses, declarations, imports, and
            // bare names (the resolver falls back to types when nothing else binds).
            return [.typeName, .member, .declared, .imported, .plain]
        case .local, .localType:
            return .all
        }
    }
}
