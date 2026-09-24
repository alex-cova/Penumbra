import Foundation

/// Identifies a refactoring operation offered by a language provider.
public struct RefactoringID: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }

    public static let extractVariable = RefactoringID("extractVariable")
    public static let extractField = RefactoringID("extractField")
    public static let extractConstant = RefactoringID("extractConstant")
    public static let extractMethod = RefactoringID("extractMethod")
    public static let inlineVariable = RefactoringID("inlineVariable")
    public static let inlineMethod = RefactoringID("inlineMethod")
    public static let changeSignature = RefactoringID("changeSignature")
    public static let encapsulateField = RefactoringID("encapsulateField")
    public static let generateAccessors = RefactoringID("generateAccessors")
    public static let moveClass = RefactoringID("moveClass")
    public static let safeDelete = RefactoringID("safeDelete")
}

/// A refactoring the provider can offer at the current selection.
public struct RefactoringDescriptor: Sendable {
    public let id: RefactoringID
    public let title: String
    public let requiresSelection: Bool
    /// Parameter keys the provider expects in ``RefactoringProviding/plan(_:context:parameters:)``.
    public let parameterKeys: [String]
    /// Default values for parameters (e.g. a suggested variable name).
    public let suggestedParameters: [String: String]

    public init(
        id: RefactoringID,
        title: String,
        requiresSelection: Bool = true,
        parameterKeys: [String] = [],
        suggestedParameters: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.requiresSelection = requiresSelection
        self.parameterKeys = parameterKeys
        self.suggestedParameters = suggestedParameters
    }
}

/// Language-specific refactorings driven by selection context.
public protocol RefactoringProviding: Sendable {
    func availableRefactorings(_ context: RefactoringContext) async -> [RefactoringDescriptor]
    func plan(
        _ id: RefactoringID, context: RefactoringContext, parameters: [String: String]
    ) async throws -> WorkspaceEditPlan
}
