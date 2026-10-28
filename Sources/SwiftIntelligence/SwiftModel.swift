import EditorIntelligence
import Foundation
import LanguageSyntax

/// What one Swift file declares, binds and uses, from a single walk of its tree-sitter tree.
///
/// Resolution is syntactic. A name binds to the innermost scope that declares it, and a type is
/// something the text states: an annotation, a constructor call, a cast, a literal, or the written
/// return type of a function the index knows. Nothing is inferred through generics, overloads or
/// the standard library.
public struct SwiftFileModel: Sendable {
    public enum Kind: String, Sendable {
        case `class`, `struct`, `enum`, actor, `protocol`, `extension`
        case function, initializer, deinitializer, `subscript`
        case property, enumCase, typeAlias, associatedType

        /// A type a value can have. An extension adds to one and is not itself a type.
        public var isNominalType: Bool {
            switch self {
            case .class, .struct, .enum, .actor, .protocol: return true
            default: return false
            }
        }

        public var isTypeLike: Bool { isNominalType || self == .typeAlias || self == .associatedType }

        /// Declarations a call can apply to.
        public var isFunctionLike: Bool {
            switch self {
            case .function, .initializer, .deinitializer, .subscript: return true
            default: return false
            }
        }
    }

    public enum Access: Int, Sendable, Comparable {
        case `private`, `fileprivate`, `internal`, `public`, open

        public static func < (lhs: Access, rhs: Access) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What a binding is, for colours and for the kind a rename announces.
    public enum SymbolKind: Sendable {
        case parameter, local, function, type

        public var highlightName: String {
            switch self {
            case .parameter: return "variable.parameter"
            case .local: return "variable.local"
            case .function: return "function.declaration"
            case .type: return "type.class"
            }
        }
    }

    public struct Parameter: Sendable, Hashable {
        /// The argument label; nil for `_`.
        public var label: String?
        public var name: String
        public var typeName: String?
        public var typeText: String?
        public var hasDefault: Bool
        public var isVariadic: Bool
    }

    public struct Declaration: Sendable {
        /// An extension is named for the type it extends; `init`, `deinit` and `subscript` for themselves.
        public var name: String
        public var kind: Kind
        public var nameBytes: Range<Int>
        /// The declaration's own text, attributes and body included.
        public var fullBytes: Range<Int>
        /// Between the braces; empty at the end of a declaration with no body.
        public var bodyBytes: Range<Int>
        public var access: Access
        public var isStatic: Bool
        public var isOverride: Bool
        /// Inherited and conformed-to type names, as written without generics. An extension lists
        /// the protocols it adds.
        public var inherits: [String]
        /// A property's annotation or a function's return type, reduced to a name; a typealias's target.
        public var typeName: String?
        public var typeText: String?
        public var parameters: [Parameter]
        public var generics: [String]
        /// `main`, `Test`, `Suite`, `objc`, … without the `@`.
        public var attributes: [String]
        public var signature: String
        public var docComment: String?
        public var members: [Declaration]
        public var isTopLevel: Bool
        /// The initializer of a property with no annotation, to be typed on demand.
        public var valueChain: SwiftChain?
        /// A `let`.
        public var isConstant = false
        /// A property given a value where it is declared.
        public var hasInitializer = false
        /// A property with a getter body rather than storage.
        public var isComputed = false

        public var isInitializer: Bool { kind == .initializer }
    }

    public struct Import: Sendable, Equatable {
        public var module: String
        public var isTestable: Bool
        /// `@_exported import X`: the module is used through its re-exports.
        public var isExported: Bool = false
        /// `import struct X.Y`: only part of the module is imported.
        public var isScoped: Bool = false
        public var bytes: Range<Int>
    }

    public struct Binding: Sendable {
        public var name: String
        public var nameBytes: Range<Int>
        /// Where the name can be used: after its declaration to the end of its block.
        public var scopeStart: Int
        public var scopeEnd: Int
        public var symbolKind: SymbolKind
        public var typeName: String?
        public var typeText: String?
        /// The value a binding without a written type was given.
        public var source: SwiftChain?
        /// `source` is a collection and the binding is one of its elements (`for x in source`).
        public var sourceIsElement: Bool
        public var isConstant: Bool
        public var signature: String?
    }

    public struct Use: Sendable {
        public enum Role: Sendable {
            /// A bare identifier in an expression: a local, a member of `self`, or a global.
            case value
            /// An identifier in a type position.
            case type
            /// `name` in `receiver.name`.
            case member(SwiftChain)
            /// `.name`, whose type the context supplies.
            case implicitMember
        }

        public var name: String
        public var bytes: Range<Int>
        public var role: Role
        public var isCall: Bool
        public var callLabels: [String]
    }

    public struct SyntaxProblem: Sendable {
        public var bytes: Range<Int>
        public var isMissing: Bool
        /// For a missing token, what the grammar expected there (`)`).
        public var expected: String?
    }

    public var declarations: [Declaration] = []
    public var imports: [Import] = []
    public var bindings: [Binding] = []
    public var uses: [Use] = []
    public var errors: [SyntaxProblem] = []
    /// The file declares an operator, a precedence group or an operator function: importing its
    /// module may be for the operator alone, which no name mentions.
    public var declaresOperators: Bool = false
    /// Every identifier-shaped token in the file, to pick the files that can mention a name.
    public var identifiers: Set<String> = []

    // MARK: Queries

    /// The innermost binding named `name` visible at `byte`.
    public func binding(named name: String, at byte: Int) -> Binding? {
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

    public func binding(atNameBytes bytes: Range<Int>) -> Binding? {
        bindings.first { $0.nameBytes == bytes }
    }

    /// The use written exactly at `bytes`.
    public func use(at bytes: Range<Int>) -> Use? {
        uses.first { $0.bytes == bytes }
    }

    /// The declaration whose name is written at `bytes`.
    public func declaration(atNameBytes bytes: Range<Int>) -> Declaration? {
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
    public func enclosingTypes(at byte: Int) -> [Declaration] {
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
    public func enclosingMember(at byte: Int) -> Declaration? {
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
    public func indexed() -> SwiftFileModel {
        var copy = self
        copy.bindings = []
        copy.uses = []
        copy.errors = []
        return copy
    }

    public func topLevelDeclarations(named name: String) -> [Declaration] {
        declarations.filter { $0.name == name && $0.kind != .extension }
    }

    public static func build(tree: LanguageSyntax.SyntaxTree, text: SourceTextMap) -> SwiftFileModel {
        SwiftModelWalker(tree: tree, text: text).build()
    }
}

/// A parsed Swift buffer: its tree, the byte-to-UTF-16 map, and the model of what is in it.
public struct SwiftParsed: Sendable {
    public var tree: LanguageSyntax.SyntaxTree
    public var text: SourceTextMap
    public var model: SwiftFileModel
}

/// Grammar-level helpers shared by the providers.
public enum SwiftNames {
    /// The identifier-like node under `byte`: the caret may sit on either edge of a token.
    public static func name(atByte byte: Int, in tree: LanguageSyntax.SyntaxTree) -> SyntaxNode? {
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

    public static func isName(_ type: String) -> Bool {
        type == "simple_identifier" || type == "type_identifier"
    }

    /// Whether `node` is inside a comment or a string literal's text (an interpolation is code).
    public static func inCommentOrString(_ node: SyntaxNode) -> Bool {
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
