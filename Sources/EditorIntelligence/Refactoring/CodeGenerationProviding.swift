import Foundation

/// A kind of member the "Generate…" action can write into a type.
public struct CodeGenerationKind: Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let constructor = CodeGenerationKind("constructor")
    public static let getter = CodeGenerationKind("getter")
    public static let setter = CodeGenerationKind("setter")
    public static let getterAndSetter = CodeGenerationKind("getterAndSetter")
    public static let toString = CodeGenerationKind("toString")
}

/// A field a generated member can be built from.
public struct CodeGenerationField: Hashable, Sendable, Identifiable {
    public let name: String
    public let typeText: String

    public init(name: String, typeText: String) {
        self.name = name
        self.typeText = typeText
    }

    public var id: String { name }
}

/// One entry of the Generate popup, with the fields the user can pick for it.
public struct CodeGenerationOption: Hashable, Sendable, Identifiable {
    public let kind: CodeGenerationKind
    public let title: String
    /// Candidates in declaration order; the host preselects all of them.
    public let fields: [CodeGenerationField]
    /// Whether generating with no field ticked is meaningful (a constructor with no parameters).
    public let allowsEmptySelection: Bool

    public init(
        kind: CodeGenerationKind, title: String, fields: [CodeGenerationField], allowsEmptySelection: Bool = false
    ) {
        self.kind = kind
        self.title = title
        self.fields = fields
        self.allowsEmptySelection = allowsEmptySelection
    }

    public var id: CodeGenerationKind { kind }
}

/// What "Generate…" can do at the caret: the type it would write into and the options on offer.
public struct CodeGenerationMenu: Sendable {
    public let typeName: String
    public let options: [CodeGenerationOption]

    public init(typeName: String, options: [CodeGenerationOption]) {
        self.typeName = typeName
        self.options = options
    }
}

/// The host's answer to a ``CodeGenerationMenu``: the option picked and the fields ticked.
public struct CodeGenerationChoice: Sendable {
    public let kind: CodeGenerationKind
    public let fieldNames: [String]

    public init(kind: CodeGenerationKind, fieldNames: [String]) {
        self.kind = kind
        self.fieldNames = fieldNames
    }
}

/// Language-specific "Generate…": constructors, accessors and `toString()` written into the
/// type around the caret.
public protocol CodeGenerationProviding: Sendable {
    /// The options available at the caret, or `nil` when the document isn't handled or the caret
    /// isn't in a type that can take generated members.
    func generationMenu(_ context: RefactoringContext) async -> CodeGenerationMenu?

    /// The edit that generates `kind` from the named fields. A plan with a `blockingError`
    /// explains why nothing was generated.
    func generate(
        _ kind: CodeGenerationKind, fieldNames: [String], context: RefactoringContext
    ) async -> WorkspaceEditPlan
}
