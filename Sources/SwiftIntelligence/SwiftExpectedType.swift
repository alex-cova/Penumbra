import EditorIntelligence
import Foundation
import LanguageSyntax

/// The type an expression must have, from what surrounds it. A leading-dot member (`.red`) has no
/// receiver, so this is all there is to look the name up on.
public enum SwiftExpectedType {
    /// The type for the expression that starts at `byte`, or nil when the context does not say.
    public static func find(at byte: Int, parsed: SwiftParsed, resolver: SwiftResolver) async -> String? {
        if let found = await findInTree(at: byte, parsed: parsed, resolver: resolver) { return found }
        return await findInText(at: byte, parsed: parsed, resolver: resolver)
    }

    /// A call's argument list read from the text, for the moment the tree has no node for it
    /// (`paint(.|)`): the callee, which argument the caret is in, and its label.
    private static func findInText(at byte: Int, parsed: SwiftParsed, resolver: SwiftResolver) async -> String? {
        guard let site = SwiftCallSite.find(parsed: parsed, at: byte) else { return nil }
        let overloads = await resolver.callees(of: site.callee, at: site.calleeStart)
        guard let chosen = site.compatible(overloads.map(\.declaration)).first,
              site.argumentIndex < chosen.parameters.count,
              let typeName = chosen.parameters[site.argumentIndex].typeName else { return nil }
        // A top-level function has no owner; a member's `Self` is the type it was found on.
        let owner = overloads.first { $0.declaration.nameBytes == chosen.nameBytes }?.owner
        return SwiftResolver.replacingSelf(SwiftTypeNames.unwrappedOptional(typeName), with: owner)
    }

    private static func findInTree(at byte: Int, parsed: SwiftParsed, resolver: SwiftResolver) async -> String? {
        let leaf = parsed.tree.node(atByteOffset: min(max(byte, 0), parsed.text.utf8.count))
        var node: SyntaxNode? = leaf
        var child: SyntaxNode = leaf
        var hops = 0
        while let current = node, hops < 14 {
            hops += 1
            switch current.type {
            case "property_declaration", "protocol_property_declaration":
                if let annotation = current.firstNamedChild(ofType: "type_annotation") {
                    let walker = SwiftModelWalker(tree: parsed.tree, text: parsed.text)
                    return walker.typeName(of: annotation).map(SwiftTypeNames.unwrappedOptional)
                }
                return nil
            case "value_argument":
                return await argumentType(current, parsed: parsed, resolver: resolver)
            case "control_transfer_statement":
                guard let function = parsed.model.enclosingMember(at: byte), function.kind == .function
                else { return nil }
                return function.typeName.map { SwiftResolver.replacingSelf($0, with: resolver.enclosingTypeName(at: byte)) }
                    .map(SwiftTypeNames.unwrappedOptional)
            case "assignment":
                guard let target = current.child(byFieldName: "target"), target.byteRange != child.byteRange else { return nil }
                return await typeName(of: target, parsed: parsed, resolver: resolver)
            case "equality_expression", "comparison_expression":
                let lhs = current.child(byFieldName: "lhs")
                let rhs = current.child(byFieldName: "rhs")
                let other = (lhs?.byteRange == child.byteRange || lhs.map { contains($0, child) } == true) ? rhs : lhs
                guard let other else { return nil }
                return await typeName(of: other, parsed: parsed, resolver: resolver)
            case "switch_pattern", "switch_entry":
                var parent = current.parent
                while let candidate = parent, candidate.type != "switch_statement" { parent = candidate.parent }
                guard let statement = parent, let subject = statement.child(byFieldName: "expr") else { return nil }
                return await typeName(of: subject, parsed: parsed, resolver: resolver)
            case "statements", "class_body", "function_body", "source_file", "lambda_literal":
                return nil
            default:
                break
            }
            child = current
            node = current.parent
        }
        return nil
    }

    private static func contains(_ outer: SyntaxNode, _ inner: SyntaxNode) -> Bool {
        outer.startByte <= inner.startByte && inner.endByte <= outer.endByte
    }

    private static func typeName(of node: SyntaxNode, parsed: SwiftParsed, resolver: SwiftResolver) async -> String? {
        let walker = SwiftModelWalker(tree: parsed.tree, text: parsed.text)
        let chain = walker.makeChain(node)
        guard let value = await resolver.value(of: chain, at: node.startByte) else { return nil }
        switch value {
        case .instance(let name): return SwiftTypeNames.unwrappedOptional(name)
        case .metatype(let name): return name
        default: return nil
        }
    }

    /// The parameter of the called function that `argument` is passed to.
    private static func argumentType(_ argument: SyntaxNode, parsed: SwiftParsed, resolver: SwiftResolver) async -> String? {
        var parent = argument.parent
        while let candidate = parent, candidate.type != "call_expression" { parent = candidate.parent }
        guard let call = parent, let callee = call.namedChild(at: 0) else { return nil }
        // Where the function's name is written: `foo(…)` or `x.foo(…)`.
        var nameNode: SyntaxNode?
        switch callee.type {
        case "simple_identifier", "type_identifier":
            nameNode = callee
        case "navigation_expression":
            nameNode = callee.child(byFieldName: "suffix")?.child(byFieldName: "suffix")
        case "constructor_expression":
            nameNode = callee.child(byFieldName: "constructed_type")?.namedChildren.last
        default:
            break
        }
        guard let nameNode, let target = await resolver.target(forNameAt: nameNode.byteRange) else { return nil }
        guard case .declaration(_, let declaration, let owner) = target else { return nil }

        // The argument's own label, and its position among the call's arguments.
        var arguments: [SyntaxNode] = []
        call.enumerateChildren { suffix, _ in
            guard suffix.type == "call_suffix" else { return }
            suffix.enumerateChildren { list, _ in
                guard list.type == "value_arguments" else { return }
                list.enumerateChildren { item, _ in
                    if item.type == "value_argument" { arguments.append(item) }
                }
            }
        }
        guard let position = arguments.firstIndex(where: { $0.byteRange == argument.byteRange }) else { return nil }
        let label = argument.child(byFieldName: "name").map { $0.namedChildren.first?.text ?? $0.text }

        var parameters = declaration.parameters
        if declaration.kind.isNominalType {
            // `Point(.zero)`: the memberwise or declared initializer with these labels.
            let members = await resolver.index.members(ofType: declaration.name, visibleFrom: resolver.url)
            let labels = arguments.map { item in
                item.child(byFieldName: "name").map { $0.namedChildren.first?.text ?? $0.text } ?? "_"
            }
            let initializer = members.first { ref in
                ref.declaration.kind == .initializer && ref.declaration.parameters.map { $0.label ?? "_" } == labels
            }
            parameters = initializer?.declaration.parameters ?? []
        }
        let parameter: SwiftFileModel.Parameter?
        if let label {
            parameter = parameters.first { $0.label == label }
        } else {
            parameter = position < parameters.count ? parameters[position] : nil
        }
        guard let typeName = parameter?.typeName else { return nil }
        return SwiftResolver.replacingSelf(SwiftTypeNames.unwrappedOptional(typeName), with: owner)
    }
}
