import Foundation

/// Who extends or implements what, for the project's own classes: supertype simple name → direct
/// subtypes. The answer to "what extends X" without decoding every project class (F15).
///
/// Keys are the simple name of each supertype *as written* (`Repository` for both `Repository<User>`
/// and `com.acme.Repository`), because a source stub spells supertypes unresolved and resolving
/// them needs the declaring file's imports. The table is therefore a candidate filter, not an
/// answer: ``JavaInheritors`` resolves each candidate's supertypes before trusting it, so two
/// unrelated classes named `Repository` never mix.
///
/// Built the way ``JavaMemberTable`` is: project shards (precedence 1 or lower) once off the actor,
/// open buffers' classes again whenever the overlay changes. JARs and the JDK are left out: an
/// implementation list of a library interface is not what `new ` or Go to Implementation want, and
/// indexing 30,000 JDK classes for it would cost far more than it returns.
struct JavaInheritorTable: Sendable {
    struct Subtype: Sendable {
        let qualifiedName: String
        let shardPath: String
        let precedence: Int
    }

    private var subtypes: [Subtype] = []
    private var bySupertypeName: [String: [Int32]] = [:]

    var isEmpty: Bool { subtypes.isEmpty }
    var count: Int { subtypes.count }

    init() {}

    static func build(from sources: [JavaIndex.Source]) -> JavaInheritorTable {
        var table = JavaInheritorTable()
        var seen = Set<String>()
        for source in sources where source.precedence <= 1 {
            for name in source.reader.allQualifiedNames where seen.insert(name).inserted {
                guard let stub = source.reader.classStub(named: name) else { continue }
                table.add(stub, shardPath: source.shardPath, precedence: source.precedence)
            }
        }
        return table
    }

    mutating func add(_ stub: JavaClassStub, shardPath: String, precedence: Int) {
        var keys = Set<String>()
        for reference in ([stub.superclass].compactMap { $0 } + stub.interfaces) {
            if let key = Self.key(of: reference) { keys.insert(key) }
        }
        guard !keys.isEmpty else { return }
        let id = Int32(subtypes.count)
        subtypes.append(Subtype(qualifiedName: stub.qualifiedName, shardPath: shardPath, precedence: precedence))
        for key in keys { bySupertypeName[key, default: []].append(id) }
    }

    /// The classes whose written supertypes include `simpleName`.
    func candidates(supertypeSimpleName simpleName: String) -> [Subtype] {
        (bySupertypeName[simpleName] ?? []).map { subtypes[Int($0)] }
    }

    /// The last segment of a supertype's name: `Map.Entry` and `java.util.Map.Entry` are `Entry`.
    static func key(of reference: JavaTypeRef) -> String? {
        let name: String
        switch reference {
        case .classType(let qualifiedName, _, _): name = qualifiedName
        case .unresolved(let simpleName, _): name = simpleName
        default: return nil
        }
        guard let last = name.split(separator: ".").last else { return nil }
        return String(last)
    }
}

extension JavaIndex {
    /// Every project class that extends or implements `qualifiedName`, directly or through other
    /// project classes, sorted by name. See ``JavaInheritors``.
    public func projectSubtypes(of qualifiedName: String) async -> [JavaClassStub] {
        await JavaInheritors.subtypes(of: qualifiedName, index: self)
    }

    /// Project classes (open buffers first, then project shards) whose written supertypes include a
    /// type called `simpleName`. Unverified: see ``JavaInheritorTable``. Honors the query scope and
    /// lets a buffer's version of a class replace its saved one.
    func projectSubtypeCandidates(supertypeSimpleName simpleName: String) async -> [JavaClassStub] {
        let base = await baseInheritorTable()
        let overlayTable = overlayInheritorTable()
        let overlayNames = Set(overlayStubs().keys)
        var seen = Set<String>()
        var result: [JavaClassStub] = []
        for candidate in overlayTable.candidates(supertypeSimpleName: simpleName) where seen.insert(candidate.qualifiedName).inserted {
            if let stub = classStub(qualifiedName: candidate.qualifiedName) { result.append(stub) }
        }
        for candidate in base.candidates(supertypeSimpleName: simpleName) {
            guard !overlayNames.contains(candidate.qualifiedName),
                  isInheritorSourceVisible(shardPath: candidate.shardPath, precedence: candidate.precedence),
                  seen.insert(candidate.qualifiedName).inserted,
                  let stub = classStub(qualifiedName: candidate.qualifiedName) else { continue }
            result.append(stub)
        }
        return result
    }
}

/// Verified subtype queries over ``JavaInheritorTable``.
enum JavaInheritors {
    /// Every project class that extends or implements `qualifiedName`, directly or through other
    /// project classes, sorted by qualified name. A class is kept only when its supertypes, resolved
    /// against its own file, name the type; a library class in between ends the walk, because the
    /// table covers project sources only.
    static func subtypes(of qualifiedName: String, index: JavaIndex) async -> [JavaClassStub] {
        var result: [JavaClassStub] = []
        var visited: Set<String> = [qualifiedName]
        var queue = [qualifiedName]
        while let target = queue.popLast() {
            let simpleName = String(target.split(separator: ".").last ?? Substring(target))
            for stub in await index.projectSubtypeCandidates(supertypeSimpleName: simpleName) {
                guard !visited.contains(stub.qualifiedName) else { continue }
                guard await JavaMemberLookup.directSupertypeNames(of: stub.qualifiedName, index: index).contains(target) else { continue }
                visited.insert(stub.qualifiedName)
                result.append(stub)
                queue.append(stub.qualifiedName)
            }
        }
        return result.sorted { $0.qualifiedName < $1.qualifiedName }
    }

    /// The classes that name `qualifiedName` as a direct supertype.
    static func directSubtypes(of qualifiedName: String, index: JavaIndex) async -> [JavaClassStub] {
        let simpleName = String(qualifiedName.split(separator: ".").last ?? Substring(qualifiedName))
        var result: [JavaClassStub] = []
        for stub in await index.projectSubtypeCandidates(supertypeSimpleName: simpleName) {
            if await JavaMemberLookup.directSupertypeNames(of: stub.qualifiedName, index: index).contains(qualifiedName) {
                result.append(stub)
            }
        }
        return result.sorted { $0.qualifiedName < $1.qualifiedName }
    }
}
