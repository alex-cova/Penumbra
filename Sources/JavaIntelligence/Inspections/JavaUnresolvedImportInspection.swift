import EditorIntelligence
import Foundation

/// `unresolved-import`: each import is judged by what it names (JLS 7.5), through the same
/// lookups the rest of the engine resolves with — `JavaIndex.classStub(qualifiedName:)` (exact,
/// honours the file's module scope), package tables, and `JavaMemberLookup` for static members.
/// Another class that shares the simple name never makes an import valid.
///
/// - `import a.b.C;` / `import a.b.C.D;` — a type with that canonical name, or a member type the
///   qualifier type inherits; it must be accessible from the file (public, or package-private in
///   the same package; a private member type is not) and exported by its module.
/// - `import a.b.*;` — a package or a type.
/// - `import static a.b.C.*;` — a type.
/// - `import static a.b.C.m;` — a type with an accessible static member `m` (field, method or
///   member type), inherited ones included.
///
/// Every verdict that depends on an open hierarchy (a supertype the index lacks, Lombok) or on
/// rules the engine does not model (protected member types) is left unjudged rather than guessed.
enum JavaUnresolvedImportInspection {
    private enum Verdict {
        case resolved
        case unknown
        case report(String, fixTitle: String?)
    }

    static func inspect(context: JavaInspectionContext, index: JavaIndex) async -> [JavaInspection] {
        let imports = context.file.imports
        guard !imports.isEmpty else { return [] }
        // See `JavaUnresolvedTypeInspection`: no claim of absence against an index that cannot prove it.
        guard await index.canProveAbsence else {
            await JavaResolutionLog.pending(rule: "unresolved-import", names: imports.map(\.qualifiedName), url: context.url, index: index)
            return []
        }
        let resolution = JavaResolutionContext.file(context.file)
        var importEntries: [JavaImportEntry]?
        var inspections: [JavaInspection] = []
        for entry in imports {
            let verdict = await judge(entry, packageName: context.file.packageName, resolution: resolution, index: index)
            guard case .report(let message, let fixTitle) = verdict else { continue }
            await JavaResolutionLog.missing(rule: "unresolved-import", name: entry.qualifiedName, url: context.url, index: index)
            if importEntries == nil { importEntries = JavaImportList(tree: context.tree).entries }
            guard let importEntry = importEntries?.first(where: { $0.qualifiedName == entry.qualifiedName && $0.isStatic == entry.isStatic }) else {
                continue
            }
            let start = JavaImportInserter.textPosition(forByteOffset: importEntry.range.lowerBound, in: context.tree.sourceBytes)
            let end = JavaImportInserter.textPosition(forByteOffset: importEntry.range.upperBound, in: context.tree.sourceBytes)
            inspections.append(JavaInspection(
                id: "unresolved-import",
                message: message,
                severity: .warning,
                range: EditorIntelligence.TextRange(start: start, end: end),
                fixTitle: fixTitle
            ))
        }
        return inspections
    }

    private static func judge(
        _ entry: JavaImportDeclaration, packageName: String, resolution: JavaResolutionContext, index: JavaIndex
    ) async -> Verdict {
        let name = entry.qualifiedName
        let missing = Verdict.report("Cannot resolve import '\(name)\(entry.isOnDemand ? ".*" : "")'", fixTitle: "Remove import")
        switch (entry.isStatic, entry.isOnDemand) {
        case (false, true):
            if await index.hasPackage(name) { return .resolved }
            guard let stub = await index.classStub(qualifiedName: name) else { return missing }
            return await access(of: stub, from: packageName, index: index)
        case (true, true):
            guard let stub = await index.classStub(qualifiedName: name) else { return missing }
            return await access(of: stub, from: packageName, index: index)
        case (false, false):
            if let stub = await index.classStub(qualifiedName: name) {
                return await access(of: stub, from: packageName, index: index)
            }
            // `import p.Sub.Inherited;` — a member type `Sub` inherits from `Super`.
            guard let (owner, member) = split(name), let ownerStub = await index.classStub(qualifiedName: owner) else { return missing }
            let ownerAccess = await access(of: ownerStub, from: packageName, index: index)
            if case .report = ownerAccess { return ownerAccess }
            guard let nested = await JavaMemberLookup.closedHierarchy(of: owner, context: resolution, index: index) else { return .unknown }
            return nested.contains(member) ? .resolved : missing
        case (true, false):
            guard let (owner, member) = split(name) else { return missing }
            guard let ownerStub = await index.classStub(qualifiedName: owner) else { return missing }
            let ownerAccess = await access(of: ownerStub, from: packageName, index: index)
            if case .report = ownerAccess { return ownerAccess }
            let type = JavaTypeRef.classType(qualifiedName: owner, arguments: [], outer: nil)
            let members = await JavaMemberLookup.members(of: type, mode: .staticOnly, context: resolution, index: index)
            if members.contains(where: { $0.name == member }) { return .resolved }
            // Member types are not members of the walk above; a static import may name one.
            if let nested = await index.classStub(qualifiedName: "\(owner).\(member)") {
                return await access(of: nested, from: packageName, index: index)
            }
            guard let inheritedTypes = await JavaMemberLookup.closedHierarchy(of: owner, context: resolution, index: index) else {
                return .unknown
            }
            if inheritedTypes.contains(member) { return .resolved }
            return .report("Cannot resolve static member '\(member)' in '\(owner)'", fixTitle: "Remove import")
        }
    }

    /// Whether the importing file (in `packageName`) may name `stub`: every level of a member type
    /// must be accessible (JLS 6.6.1), and the package must be exported to the file's module.
    /// Protected member types are left unjudged: their access depends on the class bodies that use
    /// them, not on the import.
    private static func access(of stub: JavaClassStub, from packageName: String, index: JavaIndex) async -> Verdict {
        var current: JavaClassStub? = stub
        while let level = current {
            let modifiers = level.modifiers
            if modifiers.contains(.privateFlag) {
                let owner = level.outerQualifiedName ?? level.packageName
                return .report("'\(level.qualifiedName)' has private access in '\(owner)'", fixTitle: nil)
            }
            if modifiers.contains(.protectedFlag), level.packageName != packageName { return .unknown }
            if modifiers.isPackagePrivate, level.packageName != packageName, await !isImplicitlyPublic(level, index: index) {
                if level.outerQualifiedName == nil {
                    return .report("'\(level.qualifiedName)' is not public in '\(level.packageName)'; cannot be accessed from outside package", fixTitle: nil)
                }
                return .report("'\(level.qualifiedName)' is not public in '\(level.outerQualifiedName!)'; cannot be accessed from outside package", fixTitle: nil)
            }
            guard let outer = level.outerQualifiedName else { break }
            current = await index.classStub(qualifiedName: outer)
        }
        guard await index.isExportedToQuery(qualifiedName: stub.qualifiedName) else {
            return .report("Package '\(stub.packageName)' is not exported to this module", fixTitle: nil)
        }
        return .resolved
    }

    /// A member type of an interface or annotation is implicitly public and static (JLS 9.5); a
    /// source stub carries no modifier for it.
    private static func isImplicitlyPublic(_ stub: JavaClassStub, index: JavaIndex) async -> Bool {
        guard let outer = stub.outerQualifiedName, let outerStub = await index.classStub(qualifiedName: outer) else { return false }
        return outerStub.kind == .interfaceKind || outerStub.kind == .annotationKind
    }

    private static func split(_ name: String) -> (owner: String, member: String)? {
        guard let dot = name.lastIndex(of: ".") else { return nil }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }
}
