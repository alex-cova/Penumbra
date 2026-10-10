import EditorIntelligence
import Foundation
import JavaIntelligence

/// What one Swift file declares, binds and uses, from a single walk of its tree-sitter tree.
///
/// Resolution is syntactic. A name binds to the innermost scope that declares it, and a type is
/// something the text states: an annotation, a constructor call, a cast, a literal, or the written
/// return type of a function the index knows. Nothing is inferred through generics, overloads or
/// the standard library.
struct SwiftFileModel: Sendable {
    enum Kind: String, Sendable {
        case `class`, `struct`, `enum`, actor, `protocol`, `extension`
        case function, initializer, deinitializer, `subscript`
        case property, enumCase, typeAlias, associatedType

        /// A type a value can have. An extension adds to one and is not itself a type.
        var isNominalType: Bool {
            switch self {
            case .class, .struct, .enum, .actor, .protocol: return true
            default: return false
            }
        }

        var isTypeLike: Bool { isNominalType || self == .typeAlias || self == .associatedType }

        /// Declarations a call can apply to.
        var isFunctionLike: Bool {
            switch self {
            case .function, .initializer, .deinitializer, .subscript: return true
            default: return false
            }
        }
    }

    enum Access: Int, Sendable, Comparable {
        case `private`, `fileprivate`, `internal`, `public`, open

        static func < (lhs: Access, rhs: Access) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What a binding is, for colours and for the kind a rename announces.
    enum SymbolKind: Sendable {
        case parameter, local, function, type

        var highlightName: String {
            switch self {
            case .parameter: return "variable.parameter"
            case .local: return "variable.local"
            case .function: return "function.declaration"
            case .type: return "type.class"
            }
        }
    }

    struct Parameter: Sendable, Hashable {
        /// The argument label; nil for `_`.
        var label: String?
        var name: String
        var typeName: String?
        var typeText: String?
        var hasDefault: Bool
        var isVariadic: Bool
    }

    struct Declaration: Sendable {
        /// An extension is named for the type it extends; `init`, `deinit` and `subscript` for themselves.
        var name: String
        var kind: Kind
        var nameBytes: Range<Int>
        /// The declaration's own text, attributes and body included.
        var fullBytes: Range<Int>
        /// Between the braces; empty at the end of a declaration with no body.
        var bodyBytes: Range<Int>
        var access: Access
        var isStatic: Bool
        var isOverride: Bool
        /// Inherited and conformed-to type names, as written without generics. An extension lists
        /// the protocols it adds.
        var inherits: [String]
        /// A property's annotation or a function's return type, reduced to a name; a typealias's target.
        var typeName: String?
        var typeText: String?
        var parameters: [Parameter]
        var generics: [String]
        /// `main`, `Test`, `Suite`, `objc`, … without the `@`.
        var attributes: [String]
        var signature: String
        var docComment: String?
        var members: [Declaration]
        var isTopLevel: Bool
        /// The initializer of a property with no annotation, to be typed on demand.
        var valueChain: SwiftChain?
        /// A `let`.
        var isConstant = false
        /// A property given a value where it is declared.
        var hasInitializer = false
        /// A property with a getter body rather than storage.
        var isComputed = false

        var isInitializer: Bool { kind == .initializer }
    }

    struct Import: Sendable, Equatable {
        var module: String
        var isTestable: Bool
        var bytes: Range<Int>
    }

    struct Binding: Sendable {
        var name: String
        var nameBytes: Range<Int>
        /// Where the name can be used: after its declaration to the end of its block.
        var scopeStart: Int
        var scopeEnd: Int
        var symbolKind: SymbolKind
        var typeName: String?
        var typeText: String?
        /// The value a binding without a written type was given.
        var source: SwiftChain?
        /// `source` is a collection and the binding is one of its elements (`for x in source`).
        var sourceIsElement: Bool
        var isConstant: Bool
        var signature: String?
    }

    struct Use: Sendable {
        enum Role: Sendable {
            /// A bare identifier in an expression: a local, a member of `self`, or a global.
            case value
            /// An identifier in a type position.
            case type
            /// `name` in `receiver.name`.
            case member(SwiftChain)
            /// `.name`, whose type the context supplies.
            case implicitMember
        }

        var name: String
        var bytes: Range<Int>
        var role: Role
        var isCall: Bool
        var callLabels: [String]
    }

    struct SyntaxProblem: Sendable {
        var bytes: Range<Int>
        var isMissing: Bool
        /// For a missing token, what the grammar expected there (`)`).
        var expected: String?
    }

    var declarations: [Declaration] = []
    var imports: [Import] = []
    var bindings: [Binding] = []
    var uses: [Use] = []
    var errors: [SyntaxProblem] = []
    /// Every identifier-shaped token in the file, to pick the files that can mention a name.
    var identifiers: Set<String> = []

    // MARK: Queries

    /// The innermost binding named `name` visible at `byte`.
    func binding(named name: String, at byte: Int) -> Binding? {
        var best: Binding?
        for binding in bindings where binding.name == name && binding.scopeStart <= byte && byte < binding.scopeEnd {
            guard let current = best else {
                best = binding
                continue
            }
            // The smaller scope is the inner one; a later declaration of the same size shadows.
            let span = binding.scopeEnd - binding.scopeStart
            let currentSpan = current.scopeEnd - current.scopeStart
            if span < currentSpan || (span == currentSpan && binding.scopeStart >= current.scopeStart) {
                best = binding
            }
        }
        return best
    }

    func binding(atNameBytes bytes: Range<Int>) -> Binding? {
        bindings.first { $0.nameBytes == bytes }
    }

    /// The use written exactly at `bytes`.
    func use(at bytes: Range<Int>) -> Use? {
        uses.first { $0.bytes == bytes }
    }

    /// The declaration whose name is written at `bytes`.
    func declaration(atNameBytes bytes: Range<Int>) -> Declaration? {
        var found: Declaration?
        func visit(_ declaration: Declaration) {
            if found != nil { return }
            if declaration.nameBytes == bytes {
                found = declaration
                return
            }
            guard declaration.fullBytes.lowerBound <= bytes.lowerBound, bytes.upperBound <= declaration.fullBytes.upperBound
            else { return }
            declaration.members.forEach(visit)
        }
        declarations.forEach(visit)
        return found
    }

    /// Type and extension declarations that contain `byte`, outermost first.
    func enclosingTypes(at byte: Int) -> [Declaration] {
        var chain: [Declaration] = []
        func visit(_ declaration: Declaration) {
            guard declaration.fullBytes.contains(byte) || declaration.fullBytes.upperBound == byte else { return }
            if declaration.kind.isNominalType || declaration.kind == .extension {
                chain.append(declaration)
                declaration.members.forEach(visit)
            }
        }
        declarations.forEach(visit)
        return chain
    }

    /// The member function, initializer, subscript or property whose text contains `byte`.
    func enclosingMember(at byte: Int) -> Declaration? {
        var found: Declaration?
        func visit(_ declaration: Declaration) {
            guard declaration.fullBytes.contains(byte) || declaration.fullBytes.upperBound == byte else { return }
            if !declaration.kind.isNominalType && declaration.kind != .extension { found = declaration }
            declaration.members.forEach(visit)
        }
        declarations.forEach(visit)
        return found
    }

    /// What the project index keeps of a file: its declarations, imports and identifiers. The uses,
    /// bindings and problems are what make a model large (hundreds of thousands across a project),
    /// and a query that needs them parses the file it is about.
    func indexed() -> SwiftFileModel {
        var copy = self
        copy.bindings = []
        copy.uses = []
        copy.errors = []
        return copy
    }

    func topLevelDeclarations(named name: String) -> [Declaration] {
        declarations.filter { $0.name == name && $0.kind != .extension }
    }

    static func build(tree: JavaSyntaxTree, text: SourceTextMap) -> SwiftFileModel {
        SwiftModelWalker(tree: tree, text: text).build()
    }
}

/// A parsed Swift buffer: its tree, the byte-to-UTF-16 map, and the model of what is in it.
struct SwiftParsed: Sendable {
    var tree: JavaSyntaxTree
    var text: SourceTextMap
    var model: SwiftFileModel
}

/// Grammar-level helpers shared by the providers.
enum SwiftNames {
    /// The identifier-like node under `byte`: the caret may sit on either edge of a token.
    static func name(atByte byte: Int, in tree: JavaSyntaxTree) -> SyntaxNode? {
        for probe in [byte, byte - 1] where probe >= 0 {
            var node: SyntaxNode? = tree.node(atByteOffset: probe)
            var hops = 0
            while let current = node, hops < 6 {
                if isName(current.type), current.startByte <= byte, byte <= current.endByte { return current }
                node = current.parent
                hops += 1
            }
        }
        return nil
    }

    static func isName(_ type: String) -> Bool {
        type == "simple_identifier" || type == "type_identifier"
    }

    /// Whether `node` is inside a comment or a string literal's text (an interpolation is code).
    static func inCommentOrString(_ node: SyntaxNode) -> Bool {
        var current: SyntaxNode? = node
        while let next = current {
            switch next.type {
            case "comment", "multiline_comment", "line_str_text", "multi_line_str_text", "raw_str_part", "str_escaped_char":
                return true
            case "interpolated_expression", "source_file":
                return false
            default:
                current = next.parent
            }
        }
        return false
    }
}
