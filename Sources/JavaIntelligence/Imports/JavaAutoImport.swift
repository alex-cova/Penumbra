import EditorIntelligence
import Foundation

/// Plans the import edits IntelliJ would make on its own: the one class that can resolve a
/// simple name, and the same for names that arrived in a paste.
public enum JavaAutoImport {
    /// How many unresolved names one idle pass looks up. The rest wait for the next edit.
    static let maxNames = 32
    private static let ambiguousLookupLimit = 20

    public static func edits(
        in source: String, index: JavaIndex, policy: JavaImportPolicy, caretUTF16: Int?
    ) async -> [TextEdit] {
        guard policy.addUnambiguousImportsOnTheFly else { return [] }
        return await classEdits(in: source, index: index, policy: policy, caretUTF16: caretUTF16, onlyNames: nil)
    }

    /// Imports unambiguous type names that occur in `pasted`, and only those.
    public static func edits(
        forPastedText pasted: String, in source: String, index: JavaIndex, policy: JavaImportPolicy
    ) async -> [TextEdit] {
        guard policy.insertImportsOnPaste == .always else { return [] }
        let only = Set(typeNames(in: pasted))
        guard !only.isEmpty else { return [] }
        return await classEdits(in: source, index: index, policy: policy, caretUTF16: nil, onlyNames: only)
    }

    /// "Replace with single class imports" for the star import under `caretUTF16`. Empty when a
    /// used name is ambiguous or the star imports nothing the file uses.
    static func expandStarEdits(
        in source: String, caretUTF16: Int, index: JavaIndex, policy: JavaImportPolicy
    ) async -> [TextEdit] {
        guard let tree = JavaSyntaxParser().parse(source) else { return [] }
        let list = JavaImportList(tree: tree)
        let caret = JavaNavigationText.utf8ByteOffset(forUTF16Offset: caretUTF16, in: source)
        guard let star = list.entries.first(where: { $0.isOnDemand && ($0.range.contains(caret) || $0.range.contains(caret - 1)) }) else {
            return []
        }
        let fileStubs = JavaSourceStubBuilder.build(tree: tree, url: URL(fileURLWithPath: "/unsaved/AutoImport.java"))
        let used = JavaUnusedImports.referencedSimpleNames(in: tree)
        let additions: [(qualifiedName: String, isStatic: Bool)]
        if star.isStatic {
            guard let names = await staticMembersToExpand(star: star, used: used, list: list, policy: policy, index: index) else {
                return []
            }
            additions = names.map { ("\(star.qualifiedName).\($0)", true) }
        } else {
            guard let names = await classesToExpand(
                star: star, used: used, packageName: fileStubs.packageName, policy: policy, index: index
            ) else { return [] }
            additions = names.map { ($0, false) }
        }
        guard !additions.isEmpty else { return [] }
        return JavaImportOrganizer.editsReplacing(
            star: star, with: additions, list: list, bytes: tree.sourceBytes
        )
    }

    // MARK: - Unambiguous classes

    private static func classEdits(
        in source: String, index: JavaIndex, policy: JavaImportPolicy, caretUTF16: Int?, onlyNames: Set<String>?
    ) async -> [TextEdit] {
        guard let tree = JavaSyntaxParser().parse(source) else { return [] }
        let walker = JavaSemanticWalker(tree: tree, source: source)
        guard walker.run() else { return [] }
        let fileStubs = JavaSourceStubBuilder.build(tree: tree, url: URL(fileURLWithPath: "/unsaved/AutoImport.java"))
        let list = JavaImportList(tree: tree)
        let imported = Set(list.entries.filter { !$0.isStatic && !$0.isOnDemand }.compactMap {
            $0.qualifiedName.split(separator: ".").last.map(String.init)
        })
        let caretByte = caretUTF16.map { JavaNavigationText.utf8ByteOffset(forUTF16Offset: $0, in: source) }
        let ranges = typeNameRanges(in: tree)
        var names: [String] = []
        for name in walker.undeclaredTypeNames.sorted() {
            if let onlyNames, !onlyNames.contains(name) { continue }
            if imported.contains(name) { continue }
            if let caretByte, ranges[name]?.contains(where: { $0.lowerBound <= caretByte && caretByte <= $0.upperBound }) == true {
                continue
            }
            names.append(name)
            if names.count == maxNames { break }
        }
        guard !names.isEmpty else { return [] }
        let inserter = JavaImportInserter(text: source, bytes: tree.sourceBytes, tree: tree, fileStubs: fileStubs, policy: policy)
        var additions: [(qualifiedName: String, isStatic: Bool)] = []
        for name in names {
            guard let qualified = await unambiguousClass(
                named: name, packageName: fileStubs.packageName, policy: policy, inserter: inserter, index: index
            ) else { continue }
            additions.append((qualified, false))
        }
        guard !additions.isEmpty else { return [] }
        return JavaImportOrganizer.editsAdding(additions, list: list, bytes: tree.sourceBytes, policy: policy)
    }

    /// The qualified name to import, or nil when the name is already visible, ambiguous, excluded,
    /// or not a public class.
    private static func unambiguousClass(
        named name: String, packageName: String, policy: JavaImportPolicy, inserter: JavaImportInserter, index: JavaIndex
    ) async -> String? {
        let found = await index.classes(simpleName: name, limit: ambiguousLookupLimit + 1)
        if found.count > ambiguousLookupLimit { return nil }
        let importable = found.filter { JavaImportPolicy.isImportable($0, from: packageName) && !policy.excludesClass($0) }
        var add: [String] = []
        for stub in importable {
            switch inserter.decision(for: stub) {
            case .none:
                return nil
            case .useQualifiedName:
                continue
            case .addImport:
                add.append(stub.qualifiedName)
            }
        }
        return add.count == 1 ? add[0] : nil
    }

    // MARK: - Expanding a star

    private static func classesToExpand(
        star: JavaImportEntry, used: Set<String>, packageName: String, policy: JavaImportPolicy, index: JavaIndex
    ) async -> [String]? {
        var qualified: [String] = []
        for name in used.sorted() {
            let found = await index.classes(simpleName: name, limit: ambiguousLookupLimit + 1)
            if found.count > ambiguousLookupLimit { return nil }
            let importable = found.filter { JavaImportPolicy.isImportable($0, from: packageName) && !policy.excludesClass($0) }
            let covered = importable.filter { starCovers($0, container: star.qualifiedName) }
            if covered.isEmpty { continue }
            guard covered.count == 1, covered.count == importable.count else { return nil }
            qualified.append(covered[0].qualifiedName)
        }
        return qualified
    }

    private static func staticMembersToExpand(
        star: JavaImportEntry, used: Set<String>, list: JavaImportList, policy: JavaImportPolicy, index: JavaIndex
    ) async -> [String]? {
        if list.entries.contains(where: { $0.isStatic && $0.isOnDemand && $0.qualifiedName != star.qualifiedName }) {
            return nil
        }
        guard let stub = await index.classStub(qualifiedName: star.qualifiedName) else { return nil }
        let present = Set(list.entries.filter { $0.isStatic && !$0.isOnDemand }.map(\.qualifiedName))
        var names: [String] = []
        for name in staticMemberNames(of: stub).sorted() where used.contains(name) {
            if policy.excludesStaticMember(owner: star.qualifiedName, name: name) { continue }
            if present.contains("\(star.qualifiedName).\(name)") { continue }
            names.append(name)
        }
        return names
    }

    private static func staticMemberNames(of stub: JavaClassStub) -> [String] {
        var names: [String] = []
        for method in stub.methods where !method.isConstructor && method.modifiers.contains(.staticFlag) && method.modifiers.contains(.publicFlag) {
            if !names.contains(method.name) { names.append(method.name) }
        }
        for field in stub.fields where field.modifiers.contains(.staticFlag) && field.modifiers.contains(.publicFlag) {
            if !names.contains(field.name) { names.append(field.name) }
        }
        return names
    }

    private static func starCovers(_ stub: JavaClassStub, container: String) -> Bool {
        if stub.outerQualifiedName == container { return true }
        return stub.outerQualifiedName == nil && stub.packageName == container
    }

    private static func typeNameRanges(in tree: JavaSyntaxTree) -> [String: [Range<Int>]] {
        var result: [String: [Range<Int>]] = [:]
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            if node.type == "type_identifier" {
                result[node.text, default: []].append(node.startByte..<node.endByte)
            }
            stack.append(contentsOf: node.namedChildren)
        }
        return result
    }

    /// Simple names in `pasted` that start a type (an uppercase identifier not preceded by `.`).
    static func typeNames(in pasted: String) -> [String] {
        var names: [String] = []
        var current = ""
        var previous: Character = " "
        func flush() {
            if previous != ".", let first = current.first, first.isUppercase, !names.contains(current) {
                names.append(current)
            }
            current = ""
        }
        for character in pasted {
            let continues = character.isLetter || character == "_" || character == "$" || (character.isNumber && !current.isEmpty)
            if continues {
                current.append(character)
            } else {
                flush()
                previous = character
            }
        }
        flush()
        return names
    }
}
