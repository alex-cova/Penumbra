import EditorIntelligence
import Foundation

public enum JavaMemberKind: UInt8, Sendable, Hashable {
    case method
    case field
    case enumConstant
    /// A record's header component (`record Point(int x, int y)`), listed once instead of the
    /// private field and the accessor javac derives from it.
    case recordComponent
}

/// A member declared by a project class that matched a Go to Symbol query. Positions are not
/// stored: ``JavaMemberLocator`` finds the declaration in its file when the row is opened.
public struct JavaMemberMatch: Sendable, Equatable {
    public let ownerQualifiedName: String
    public let ownerSimpleName: String
    public let packageName: String
    public let name: String
    public let kind: JavaMemberKind
    /// `(String, int)` for a method, empty for the others.
    public let parameterList: String
    /// The return type of a method, the type of a field or component, empty for an enum constant.
    public let typeText: String
    /// Simple type names of a method's parameters, to tell overloads apart in the source.
    public let parameterKeys: [String]
    public let isStatic: Bool
    public let isDeprecated: Bool
    /// The source file that declares the owner.
    public let url: URL
    public let tier: CompletionMatcher.Tier
}

/// The members of the project's classes, flat, for Go to Symbol. Built once from the decoded
/// class stubs (the spike in `docs/INTELLIJ_SMALLER_GAPS_PLAN.md` measured ~50 ms and ~10 MB for
/// 150,000 members), so a lookup never decodes a class body except for the few rows it returns.
///
/// Matching follows ``CompletionMatcher``, which only ever matches at a word start (a prefix, a
/// camel-hump run, or a later word). Entries are therefore bucketed by the lowercased first letter
/// of each of their words: a query needs one bucket, then a cheap in-order letter check runs
/// before the matcher (which allocates), and ranking keeps a running top of `limit`.
struct JavaMemberTable: Sendable {
    struct Owner: Sendable {
        let qualifiedName: String
        let simpleName: String
        let packageName: String
        let url: URL
        let shardPath: String
        let precedence: Int
    }

    struct Entry: Sendable {
        let lower: String
        let name: String
        let owner: Int32
        let kind: JavaMemberKind
        /// Index into the owner stub's `methods` (for a method) or `fields` (for the others).
        let slot: Int32
    }

    private(set) var owners: [Owner] = []
    private(set) var entries: [Entry] = []
    private var buckets = [[Int32]](repeating: [], count: JavaWordBuckets.count)

    var isEmpty: Bool { entries.isEmpty }

    init() {}

    /// The project's own classes (precedence 1 or lower) from `sources`, one stub decoded at a time
    /// so the build never holds them all. The first source defining a name wins, as in lookups.
    static func build(from sources: [JavaIndex.Source]) -> JavaMemberTable {
        var table = JavaMemberTable()
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
        guard case .source(let url, _) = stub.origin else { return }
        let ownerID = Int32(owners.count)
        var added = false
        func append(_ name: String, _ kind: JavaMemberKind, slot: Int) {
            let entryID = Int32(entries.count)
            entries.append(Entry(lower: name.lowercased(), name: name, owner: ownerID, kind: kind, slot: Int32(slot)))
            JavaWordBuckets.wordInitials(of: name) { buckets[Int($0)].append(entryID) }
            added = true
        }

        let componentNames: Set<String> = stub.kind == .recordKind
            ? Set(stub.fields.filter { !$0.modifiers.contains(.staticFlag) }.map(\.name))
            : []
        for (slot, method) in stub.methods.enumerated() {
            if method.isConstructor { continue }
            if method.modifiers.contains(.synthetic) || method.modifiers.contains(.bridge) { continue }
            // javac gives every enum `values()` and `valueOf(String)`; they are not in the source.
            if stub.kind == .enumKind, method.modifiers.contains(.staticFlag),
               (method.name == "values" && method.parameters.isEmpty) || (method.name == "valueOf" && method.parameters.count == 1) {
                continue
            }
            // A record's accessors are its components, which are listed as such.
            if stub.kind == .recordKind, method.parameters.isEmpty, componentNames.contains(method.name) { continue }
            append(method.name, .method, slot: slot)
        }
        for (slot, field) in stub.fields.enumerated() {
            if field.modifiers.contains(.synthetic) { continue }
            if field.modifiers.contains(.enumConstant) {
                append(field.name, .enumConstant, slot: slot)
            } else if stub.kind == .recordKind, !field.modifiers.contains(.staticFlag) {
                append(field.name, .recordComponent, slot: slot)
            } else {
                append(field.name, .field, slot: slot)
            }
        }
        if added {
            owners.append(Owner(
                qualifiedName: stub.qualifiedName, simpleName: stub.simpleName, packageName: stub.packageName,
                url: url, shardPath: shardPath, precedence: precedence
            ))
        }
    }

    struct Candidate: Sendable {
        let entry: Int32
        let match: CompletionMatcher.Match
    }

    /// The best `limit` matches, best first. `isSkipped` drops whole owners (a class the overlay
    /// replaces, or a shard the query scope hides).
    func matches(query: String, limit: Int, isSkipped: (Owner) -> Bool) -> [Candidate] {
        guard limit > 0, let first = JavaWordBuckets.bucketKey(of: query) else { return [] }
        let lowered = Array(query.lowercased().utf8)
        var top: [(score: Int, candidate: Candidate)] = []
        var floor = Int.min
        var skippedOwner: [Int32: Bool] = [:]
        for entryID in buckets[Int(first)] {
            let entry = entries[Int(entryID)]
            guard JavaWordBuckets.isSubsequence(lowered, of: entry.lower) else { continue }
            if let skipped = skippedOwner[entry.owner] {
                if skipped { continue }
            } else {
                let skipped = isSkipped(owners[Int(entry.owner)])
                skippedOwner[entry.owner] = skipped
                if skipped { continue }
            }
            guard let match = CompletionMatcher.match(query, in: entry.name) else { continue }
            // Shorter names first among equal matches, as the class lookup does.
            let score = match.degree * 1_000 - min(entry.name.utf8.count, 999)
            guard score > floor || top.count < limit else { continue }
            top.append((score, Candidate(entry: entryID, match: match)))
            if top.count >= limit * 2 {
                top.sort { $0.score > $1.score }
                top.removeLast(top.count - limit)
                floor = top[limit - 1].score
            }
        }
        top.sort { $0.score > $1.score }
        return top.prefix(limit).map(\.candidate)
    }
}

extension JavaMemberMatch {
    /// The decoded stub member behind a table entry, or `nil` when the class changed shape since.
    init?(entry: JavaMemberTable.Entry, owner: JavaMemberTable.Owner, stub: JavaClassStub, tier: CompletionMatcher.Tier) {
        let slot = Int(entry.slot)
        switch entry.kind {
        case .method:
            guard slot < stub.methods.count, stub.methods[slot].name == entry.name else { return nil }
            let method = stub.methods[slot]
            self.init(
                ownerQualifiedName: owner.qualifiedName, ownerSimpleName: owner.simpleName, packageName: owner.packageName,
                name: entry.name, kind: .method, parameterList: method.parameterListDisplay,
                typeText: method.returnType.simpleDisplayName, parameterKeys: JavaTypeKeys.keys(of: method),
                isStatic: method.modifiers.contains(.staticFlag), isDeprecated: method.modifiers.contains(.deprecatedFlag),
                url: owner.url, tier: tier
            )
        case .field, .enumConstant, .recordComponent:
            guard slot < stub.fields.count, stub.fields[slot].name == entry.name else { return nil }
            let field = stub.fields[slot]
            self.init(
                ownerQualifiedName: owner.qualifiedName, ownerSimpleName: owner.simpleName, packageName: owner.packageName,
                name: entry.name, kind: entry.kind, parameterList: "",
                typeText: entry.kind == .enumConstant ? "" : field.type.simpleDisplayName, parameterKeys: [],
                isStatic: field.modifiers.contains(.staticFlag), isDeprecated: field.modifiers.contains(.deprecatedFlag),
                url: owner.url, tier: tier
            )
        }
    }
}

/// Finds a member's declaration in its source file. The index stores no positions, so a stale one
/// can never send the caret to the wrong place: the file as it is now is parsed and searched by
/// owner, name and parameter types.
public enum JavaMemberLocator {
    /// The UTF-8 byte range of the member's name in `source`. When the member is no longer there
    /// (the file changed since it was indexed) the owner's name is returned instead, so the row
    /// still opens the right class; `nil` only when `source` does not parse or lacks the owner too.
    public static func nameRange(of member: JavaMemberMatch, in source: String) -> Range<Int>? {
        guard let tree = JavaSyntaxParser().parse(source) else { return nil }
        let owner = member.ownerQualifiedName
        var found: Range<Int>?
        switch member.kind {
        case .method:
            found = JavaDeclarationLocator.methodRanges(
                declaringClass: owner, name: member.name, parameterKeys: member.parameterKeys,
                isConstructor: false, in: tree
            ).first
        case .recordComponent:
            found = JavaDeclarationLocator.methodRanges(
                declaringClass: owner, name: member.name, parameterKeys: [], isConstructor: false, in: tree
            ).first ?? JavaDeclarationLocator.fieldRanges(declaringClass: owner, name: member.name, in: tree).first
        case .field, .enumConstant:
            found = JavaDeclarationLocator.fieldRanges(declaringClass: owner, name: member.name, in: tree).first
        }
        return found ?? JavaDeclarationLocator.typeName(qualifiedName: owner, in: tree)
    }
}

extension JavaIndex {
    /// Members declared by project classes (the open-document overlay and project source shards;
    /// never JARs or the JDK, and never inherited ones) whose name matches `query` the way
    /// IntelliJ's Go to Symbol does: prefix, camel-hump (`gN` → `getName`), or from a later word
    /// (`Name` → `getName`). Best match first, capped at `limit`.
    ///
    /// The first call after the sources change builds the table off the actor (~50 ms per 150,000
    /// members); later calls scan one bucket of it. An open buffer's classes replace the stored
    /// ones of the same name, like the class table.
    public func members(matching query: String, limit: Int = 100) async -> [JavaMemberMatch] {
        guard !query.isEmpty else { return [] }
        let base = await baseMemberTable()
        let overlayTable = overlayMemberTable()
        let overlayNames = Set(overlayStubs().keys)

        var found: [(candidate: JavaMemberTable.Candidate, table: JavaMemberTable, isOverlay: Bool)] = []
        for candidate in overlayTable.matches(query: query, limit: limit, isSkipped: { _ in false }) {
            found.append((candidate, overlayTable, true))
        }
        for candidate in base.matches(query: query, limit: limit, isSkipped: { owner in
            overlayNames.contains(owner.qualifiedName) || !isMemberOwnerVisible(owner)
        }) {
            found.append((candidate, base, false))
        }
        found.sort { lhs, rhs in
            let l = lhs.candidate.match, r = rhs.candidate.match
            if l.degree != r.degree { return l.degree > r.degree }
            let le = lhs.table.entries[Int(lhs.candidate.entry)], re = rhs.table.entries[Int(rhs.candidate.entry)]
            if le.name.utf8.count != re.name.utf8.count { return le.name.utf8.count < re.name.utf8.count }
            let lo = lhs.table.owners[Int(le.owner)].qualifiedName, ro = rhs.table.owners[Int(re.owner)].qualifiedName
            if lo != ro { return lo < ro }
            if le.name != re.name { return le.name < re.name }
            return le.slot < re.slot
        }

        var result: [JavaMemberMatch] = []
        for item in found {
            guard result.count < limit else { break }
            let entry = item.table.entries[Int(item.candidate.entry)]
            let owner = item.table.owners[Int(entry.owner)]
            let stub = classStub(qualifiedName: owner.qualifiedName)
            guard let stub, let match = JavaMemberMatch(entry: entry, owner: owner, stub: stub, tier: item.candidate.match.tier) else { continue }
            result.append(match)
        }
        return result
    }
}
