import Foundation

/// What one module shows the rest of the project: every name it declares, and the three reasons an
/// import can be load-bearing without any of those names being mentioned — re-exports, operators,
/// and conformances added to types the module does not declare. Built from the indexed models and
/// cached per module; `nil` from ``SwiftIndex/moduleSurface(_:)`` means the index does not know the
/// module (the SDK, dependencies, anything outside the module resolver).
public struct SwiftModuleSurface: Sendable, Equatable {
    /// Every declared name: types, top-level functions and variables, members, and members of
    /// extensions (even of outside types — an extension member can satisfy a use).
    public var names: Set<String>
    /// Some file re-exports another module (`@_exported import`): the import may be for what comes through.
    public var hasReexports: Bool
    /// Some file declares an operator, a precedence group or an operator function, which is used
    /// without being named.
    public var declaresOperators: Bool
    /// Some file extends a type the module does not declare and adds a conformance: the import may
    /// be for the conformance, which is also used without being named.
    public var hasRetroactiveConformances: Bool

    public init(names: Set<String> = [], hasReexports: Bool = false, declaresOperators: Bool = false, hasRetroactiveConformances: Bool = false) {
        self.names = names
        self.hasReexports = hasReexports
        self.declaresOperators = declaresOperators
        self.hasRetroactiveConformances = hasRetroactiveConformances
    }

    /// Folds one indexed file's model into the surface of its module.
    static func build(files: [SwiftFileModel]) -> SwiftModuleSurface {
        var surface = SwiftModuleSurface()
        var declaredTypes: Set<String> = []
        for file in files {
            if file.declaresOperators { surface.declaresOperators = true }
            if file.imports.contains(where: \.isExported) { surface.hasReexports = true }
            collect(namesOf: file.declarations, into: &surface.names, typesInto: &declaredTypes)
        }
        for file in files {
            if extendsOutsideType(file.declarations, declaredTypes: declaredTypes) {
                surface.hasRetroactiveConformances = true
                break
            }
        }
        return surface
    }

    private static func collect(
        namesOf declarations: [SwiftFileModel.Declaration], into names: inout Set<String>, typesInto types: inout Set<String>
    ) {
        for declaration in declarations {
            names.insert(declaration.name)
            if declaration.kind.isNominalType { types.insert(declaration.name) }
            collect(namesOf: declaration.members, into: &names, typesInto: &types)
        }
    }

    /// An extension that adds a protocol to a type no file of the module declares.
    private static func extendsOutsideType(
        _ declarations: [SwiftFileModel.Declaration], declaredTypes: Set<String>
    ) -> Bool {
        for declaration in declarations {
            if declaration.kind == .extension, !declaration.inherits.isEmpty,
               !declaredTypes.contains(baseName(of: declaration.name)) {
                return true
            }
            if extendsOutsideType(declaration.members, declaredTypes: declaredTypes) { return true }
        }
        return false
    }

    /// `Foo<T>` to `Foo`, `A.B` to `B`: the name matching is by the last component, so an
    /// unrecognized shape errs toward a conformance (the import stays).
    private static func baseName(of extended: String) -> String {
        let dotted = extended.split(separator: ".").last.map(String.init) ?? extended
        if let generic = dotted.firstIndex(of: "<") { return String(dotted[..<generic]) }
        return dotted
    }
}

/// What `unused-import` asks of the index: the project's names (for `unused-declaration`) plus the
/// surface of a module and the module of a file. Both hop to the index, like `filesMentioning`.
public protocol SwiftModuleSurfaceLookup: SwiftProjectNameLookup {
    /// The module's surface, or `nil` when the index does not know the module.
    func moduleSurface(_ module: String) async -> SwiftModuleSurface?
    /// The module the index attributes the file to, if any.
    func module(ofFile url: URL) async -> String?
}
