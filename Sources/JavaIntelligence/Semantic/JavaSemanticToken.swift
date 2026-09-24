import Foundation

/// What an identifier in Java source is, as far as a syntax-and-scope pass can tell.
public enum JavaSemanticTokenKind: String, Sendable, CaseIterable {
    case classType
    case interfaceType
    case enumType
    case recordType
    case annotationType
    case typeParameter
    case methodDeclaration
    case methodCall
    case constructor
    case field
    case enumConstant
    case parameter
    case localVariable
}

/// One classified identifier: its UTF-16 range in the source and what it is.
public struct JavaSemanticToken: Sendable, Hashable {
    public let range: Range<Int>
    public let kind: JavaSemanticTokenKind
    public let isStatic: Bool
    public let isFinal: Bool
    /// The identifier is the name being declared, not a use of it.
    public let isDeclaration: Bool

    public init(range: Range<Int>, kind: JavaSemanticTokenKind, isStatic: Bool = false, isFinal: Bool = false, isDeclaration: Bool = false) {
        self.range = range
        self.kind = kind
        self.isStatic = isStatic
        self.isFinal = isFinal
        self.isDeclaration = isDeclaration
    }

    /// The highlight name a theme colours this token by. Each peels to a base name themes already
    /// know (`type`, `function`, `variable`, `constant`, `property`), so a theme that ignores the
    /// extra detail still gets sensible colours.
    public var highlightName: String {
        switch kind {
        case .classType: return "type.class"
        case .interfaceType: return "type.interface"
        case .enumType: return "type.enum"
        case .recordType: return "type.record"
        case .annotationType: return "attribute"
        case .typeParameter: return "type.parameter"
        case .methodDeclaration: return "function.declaration"
        case .methodCall: return isStatic ? "function.call.static" : "function.call"
        case .constructor: return "constructor"
        case .field:
            if isStatic && isFinal { return "constant.static" }
            return isStatic ? "property.static" : "property"
        case .enumConstant: return "constant.enum"
        case .parameter: return "variable.parameter"
        case .localVariable: return "variable.local"
        }
    }
}
