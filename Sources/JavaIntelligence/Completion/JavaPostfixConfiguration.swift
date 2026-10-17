import EditorIntelligence
import Foundation

/// One user-written postfix template. `$EXPR$` is the receiver; the rest is a snippet.
public struct JavaPostfixCustomTemplate: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var key: String
    public var applicable: ApplicableType
    public var body: String
    /// When set, only the outermost expression that ends at the dot is offered.
    public var topmost: Bool
    /// The first `pkg.Class.member(` in the body becomes a static import when the simple name is free.
    public var useStaticImport: Bool

    public init(
        id: UUID = UUID(),
        key: String,
        applicable: ApplicableType = .any,
        body: String = "$EXPR$$0",
        topmost: Bool = false,
        useStaticImport: Bool = false
    ) {
        self.id = id
        self.key = key
        self.applicable = applicable
        self.body = body
        self.topmost = topmost
        self.useStaticImport = useStaticImport
    }

    public enum ApplicableType: Codable, Sendable, Equatable, Hashable {
        case any
        case boolean
        case nonVoid
        case iterable
        case array
        case string
        case number
        case qualifiedClass(String)

        public var title: String {
            switch self {
            case .any: return "Any"
            case .boolean: return "Boolean"
            case .nonVoid: return "Non-void"
            case .iterable: return "Iterable"
            case .array: return "Array"
            case .string: return "String"
            case .number: return "Number"
            case .qualifiedClass: return "Class"
            }
        }

        func matches(_ type: JavaTypeRef, isIterable: Bool, assignability: JavaAssignability) async -> Bool {
            switch self {
            case .any:
                return true
            case .boolean:
                return JavaPostfixTypes.isBoolean(type)
            case .nonVoid:
                return type != .void
            case .iterable:
                return isIterable
            case .array:
                if case .array = type { return true }
                return false
            case .string:
                return type.erasedQualifiedName == "java.lang.String"
            case .number:
                return JavaPostfixTypes.isNumber(type)
            case .qualifiedClass(let name):
                let expected = JavaTypeRef.classType(qualifiedName: name, arguments: [], outer: nil)
                return await assignability.isAssignable(type, to: expected)
            }
        }
    }
}

/// Which postfix templates are offered, and which key expands one when the popup is closed.
public struct JavaPostfixConfiguration: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    /// Built-in keys the user turned off. Sorted, so equality ignores toggle order.
    public var disabledKeys: [String]
    public var expansionKey: PostfixExpansionKey
    public var customTemplates: [JavaPostfixCustomTemplate]

    public init(
        isEnabled: Bool = true,
        disabledKeys: [String] = [],
        expansionKey: PostfixExpansionKey = .tab,
        customTemplates: [JavaPostfixCustomTemplate] = []
    ) {
        self.isEnabled = isEnabled
        self.disabledKeys = disabledKeys
        self.expansionKey = expansionKey
        self.customTemplates = customTemplates
    }

    public static let standard = JavaPostfixConfiguration()

    /// Built-in template keys, in settings order.
    public static let builtInKeys: [String] = [
        "not", "if", "else", "while", "assert", "nn", "null",
        "for", "fori", "forr", "var", "return", "sout", "soutv", "serr", "souf",
        "cast", "castvar", "inst", "instanceof", "opt", "reqnonnull", "synchronized", "field",
        "lambda", "par", "arg", "switch", "try", "stream", "format", "throw", "twr", "new"
    ]

    public var templateKeys: Set<String> {
        guard isEnabled else { return [] }
        let disabled = Set(disabledKeys)
        var keys = Set(Self.builtInKeys).subtracting(disabled)
        for template in customTemplates where !template.key.isEmpty {
            keys.insert(template.key)
        }
        return keys
    }

    public func allows(_ key: String) -> Bool {
        isEnabled && !disabledKeys.contains(key)
    }

    public var expansionSettings: PostfixExpansionSettings {
        PostfixExpansionSettings(isEnabled: isEnabled, key: expansionKey, templateKeys: templateKeys)
    }
}

enum JavaPostfixTypes {
    static func isBoolean(_ type: JavaTypeRef) -> Bool {
        type == .primitive(.boolean) || type.erasedQualifiedName == "java.lang.Boolean"
    }

    static func isReference(_ type: JavaTypeRef) -> Bool {
        switch type {
        case .primitive, .void: return false
        default: return true
        }
    }

    static func isNumber(_ type: JavaTypeRef) -> Bool {
        switch type {
        case .primitive(let primitive):
            switch primitive {
            case .byte, .short, .int, .long, .float, .double: return true
            case .boolean, .char: return false
            }
        case .classType(let name, _, _):
            return numberClasses.contains(name)
        default:
            return false
        }
    }

    static func isSwitchSelector(_ type: JavaTypeRef, isEnum: Bool) -> Bool {
        if isEnum { return true }
        if type.erasedQualifiedName == "java.lang.String" { return true }
        switch type {
        case .primitive(let primitive):
            return primitive == .int || primitive == .short || primitive == .byte || primitive == .char
        case .classType(let name, _, _):
            return switchBoxes.contains(name)
        default:
            return false
        }
    }

    private static let numberClasses: Set<String> = [
        "java.lang.Byte", "java.lang.Short", "java.lang.Integer", "java.lang.Long",
        "java.lang.Float", "java.lang.Double"
    ]

    private static let switchBoxes: Set<String> = [
        "java.lang.Integer", "java.lang.Short", "java.lang.Byte", "java.lang.Character"
    ]
}
