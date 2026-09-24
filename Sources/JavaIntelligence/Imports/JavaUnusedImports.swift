import EditorIntelligence
import Foundation

/// Finds the imports of a Java file that can be deleted: the ones nothing in the file refers to,
/// duplicates, and imports of `java.lang` or of the file's own package.
///
/// This is deliberately conservative. A name counts as used when it appears as any identifier
/// outside the `package` and `import` declarations, or in a Javadoc `{@link}` / `@see` /
/// `@throws` reference, whatever it actually resolves to. On-demand (`*`) imports are always
/// kept, and a file with a syntax error yields no edits at all.
enum JavaUnusedImports {
    /// One edit per removable import, each deleting the whole line. Ordered last import first, so
    /// applying them in sequence never invalidates a later range.
    static func edits(in source: String) -> [TextEdit] {
        guard let analysis = analyze(source), !analysis.removable.isEmpty else { return [] }
        let bytes = analysis.tree.sourceBytes
        return analysis.removable.reversed().map { entry in
            let range = lineRange(of: entry.range, in: bytes)
            return TextEdit(
                range: EditorIntelligence.TextRange(
                    start: JavaImportInserter.textPosition(forByteOffset: range.lowerBound, in: bytes),
                    end: JavaImportInserter.textPosition(forByteOffset: range.upperBound, in: bytes)
                ),
                replacement: ""
            )
        }
    }

    /// The parsed file, its imports and the ones that can go; `nil` for a file with a syntax error.
    struct Analysis {
        let tree: JavaSyntaxTree
        let list: JavaImportList
        let removable: [JavaImportEntry]
    }

    static func analyze(_ source: String) -> Analysis? {
        guard let tree = JavaSyntaxParser().parse(source), !tree.rootNode.hasError else { return nil }
        let list = JavaImportList(tree: tree)
        return Analysis(tree: tree, list: list, removable: removableImports(in: list, used: usedNames(in: tree)))
    }

    private static func removableImports(in list: JavaImportList, used: Set<String>) -> [JavaImportEntry] {
        var seen = Set<String>()
        var removable: [JavaImportEntry] = []
        for entry in list.entries {
            let key = "\(entry.isStatic ? "static " : "")\(entry.qualifiedName)\(entry.isOnDemand ? ".*" : "")"
            if !seen.insert(key).inserted {
                removable.append(entry)
                continue
            }
            if entry.isOnDemand { continue }
            let parts = entry.qualifiedName.split(separator: ".").map(String.init)
            guard let simpleName = parts.last else { continue }
            if !entry.isStatic {
                let package = parts.dropLast().joined(separator: ".")
                if package == "java.lang" || (package == list.packageName && !package.isEmpty) {
                    removable.append(entry)
                    continue
                }
            }
            if !used.contains(simpleName) {
                removable.append(entry)
            }
        }
        return removable
    }

    // MARK: - Used names

    private static func usedNames(in tree: JavaSyntaxTree) -> Set<String> {
        var names = Set<String>()
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            switch node.type {
            case "import_declaration", "package_declaration":
                continue
            case "identifier", "type_identifier":
                names.insert(node.text)
            case "block_comment":
                names.formUnion(javadocReferences(in: node.text))
            default:
                break
            }
            stack.append(contentsOf: node.children)
        }
        return names
    }

    /// The leading simple name of every `{@link X}`, `{@linkplain X#m}`, `@see X`, `@throws X`
    /// and `@exception X` in a Javadoc comment.
    private static func javadocReferences(in comment: String) -> Set<String> {
        guard comment.hasPrefix("/**") else { return [] }
        let pattern = #"(?:\{@(?:link|linkplain|value)|@see|@throws|@exception)\s+([A-Za-z_$][\w$]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = comment as NSString
        var names = Set<String>()
        for match in regex.matches(in: comment, range: NSRange(location: 0, length: ns.length)) {
            names.insert(ns.substring(with: match.range(at: 1)))
        }
        return names
    }

    // MARK: - Ranges

    /// The declaration's whole line: from the start of the line when only blanks precede it, to
    /// just past the line break that follows it (or the end of the file).
    static func lineRange(of range: Range<Int>, in bytes: [UInt8]) -> Range<Int> {
        var start = range.lowerBound
        var probe = start
        while probe > 0, bytes[probe - 1] == 32 || bytes[probe - 1] == 9 { probe -= 1 }
        if probe == 0 || bytes[probe - 1] == 10 { start = probe }
        var end = range.upperBound
        while end < bytes.count, bytes[end] == 32 || bytes[end] == 9 { end += 1 }
        if end < bytes.count, bytes[end] == 13 { end += 1 }
        if end < bytes.count, bytes[end] == 10 { end += 1 }
        return start..<end
    }
}
