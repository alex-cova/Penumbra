import Foundation

public enum JavaTypeKind: UInt8, Hashable, Sendable {
    case classKind
    case interfaceKind
    case enumKind
    case recordKind
    case annotationKind
}

/// Where a stub's data came from, so the index can order results (source > JAR > JDK) and so a
/// completion provider can jump to the declaration when it's a source file.
public enum JavaStubOrigin: Hashable, Sendable {
    /// A class file inside the running JDK (ct.sym or jmods), identified by its module.
    case jdkModule(String)
    /// A class file inside a resolved dependency JAR, identified by the JAR's path.
    case jar(URL)
    /// A `.java` source file, identified by its URL and the byte range of the declaration name.
    case source(URL, nameRange: Range<Int>)
}

/// Visibility/behavior flags relevant to completion, decoded from `access_flags` plus modifiers
/// parsed from source.
public struct JavaModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let publicFlag = JavaModifiers(rawValue: 1 << 0)
    public static let privateFlag = JavaModifiers(rawValue: 1 << 1)
    public static let protectedFlag = JavaModifiers(rawValue: 1 << 2)
    public static let staticFlag = JavaModifiers(rawValue: 1 << 3)
    public static let finalFlag = JavaModifiers(rawValue: 1 << 4)
    public static let abstractFlag = JavaModifiers(rawValue: 1 << 5)
    public static let synthetic = JavaModifiers(rawValue: 1 << 6)
    public static let bridge = JavaModifiers(rawValue: 1 << 7)
    public static let varargs = JavaModifiers(rawValue: 1 << 8)
    public static let deprecatedFlag = JavaModifiers(rawValue: 1 << 9)
    public static let defaultMethod = JavaModifiers(rawValue: 1 << 10)
    public static let enumConstant = JavaModifiers(rawValue: 1 << 11)

    /// Package-private is "none of public/private/protected".
    public var isPackagePrivate: Bool {
        !contains(.publicFlag) && !contains(.privateFlag) && !contains(.protectedFlag)
    }
}

public struct JavaParameterStub: Hashable, Sendable {
    public let name: String?
    public let type: JavaTypeRef

    public init(name: String?, type: JavaTypeRef) {
        self.name = name
        self.type = type
    }
}

public struct JavaMethodStub: Hashable, Sendable {
    public let name: String
    public let typeParameters: [JavaTypeParameter]
    public let parameters: [JavaParameterStub]
    public let returnType: JavaTypeRef
    public let thrownTypes: [JavaTypeRef]
    public let modifiers: JavaModifiers
    public let isConstructor: Bool
    public let javadoc: String?

    public init(
        name: String,
        typeParameters: [JavaTypeParameter] = [],
        parameters: [JavaParameterStub],
        returnType: JavaTypeRef,
        thrownTypes: [JavaTypeRef] = [],
        modifiers: JavaModifiers,
        isConstructor: Bool = false,
        javadoc: String? = nil
    ) {
        self.name = name
        self.typeParameters = typeParameters
        self.parameters = parameters
        self.returnType = returnType
        self.thrownTypes = thrownTypes
        self.modifiers = modifiers
        self.isConstructor = isConstructor
        self.javadoc = javadoc
    }

    /// A short IntelliJ-style signature for the completion popup, e.g. "(String s, int n)".
    public var parameterListDisplay: String {
        let parts = parameters.map { p -> String in
            let type = p.type.simpleDisplayName
            if let name = p.name { return "\(type) \(name)" }
            return type
        }
        return "(\(parts.joined(separator: ", ")))"
    }
}

public struct JavaFieldStub: Hashable, Sendable {
    public let name: String
    public let type: JavaTypeRef
    public let modifiers: JavaModifiers
    public let javadoc: String?

    public init(name: String, type: JavaTypeRef, modifiers: JavaModifiers, javadoc: String? = nil) {
        self.name = name
        self.type = type
        self.modifiers = modifiers
        self.javadoc = javadoc
    }
}

/// A parsed, decoded view of one Java class/interface/enum/record/annotation, independent of
/// whether it came from a `.class` file, a `.jar`, or a `.java` source file.
public struct JavaClassStub: Hashable, Sendable {
    /// Binary/erased name using '$' for nested types, e.g. "java.util.Map$Entry".
    public let binaryName: String
    /// Qualified source name using '.' throughout, e.g. "java.util.Map.Entry".
    public let qualifiedName: String
    public let simpleName: String
    public let packageName: String
    /// The qualified name of the immediately enclosing type, if this is a (non-local, non-anonymous)
    /// nested type.
    public let outerQualifiedName: String?
    public let kind: JavaTypeKind
    public let modifiers: JavaModifiers
    public let typeParameters: [JavaTypeParameter]
    public let superclass: JavaTypeRef?
    public let interfaces: [JavaTypeRef]
    public let fields: [JavaFieldStub]
    public let methods: [JavaMethodStub]
    public let innerTypeNames: [String]
    public let origin: JavaStubOrigin
    public let javadoc: String?

    public init(
        binaryName: String,
        qualifiedName: String,
        simpleName: String,
        packageName: String,
        outerQualifiedName: String? = nil,
        kind: JavaTypeKind,
        modifiers: JavaModifiers,
        typeParameters: [JavaTypeParameter] = [],
        superclass: JavaTypeRef? = nil,
        interfaces: [JavaTypeRef] = [],
        fields: [JavaFieldStub] = [],
        methods: [JavaMethodStub] = [],
        innerTypeNames: [String] = [],
        origin: JavaStubOrigin,
        javadoc: String? = nil
    ) {
        self.binaryName = binaryName
        self.qualifiedName = qualifiedName
        self.simpleName = simpleName
        self.packageName = packageName
        self.outerQualifiedName = outerQualifiedName
        self.kind = kind
        self.modifiers = modifiers
        self.typeParameters = typeParameters
        self.superclass = superclass
        self.interfaces = interfaces
        self.fields = fields
        self.methods = methods
        self.innerTypeNames = innerTypeNames
        self.origin = origin
        self.javadoc = javadoc
    }

    public var isDeprecated: Bool { modifiers.contains(.deprecatedFlag) }
}
