import Foundation

/// One `import` declaration of a Java file, with its UTF-8 byte range.
struct JavaImportEntry: Equatable {
    var qualifiedName: String
    var isStatic: Bool
    var isOnDemand: Bool
    var range: Range<Int>
}

/// The top-level `import` declarations of a parsed Java file, in source order.
struct JavaImportList {
    private(set) var entries: [JavaImportEntry] = []
    /// End byte of the `package` declaration, when there is one.
    private(set) var packageDeclarationEnd: Int?
    /// The declared package, or `""` for the default package.
    private(set) var packageName = ""

    init(tree: JavaSyntaxTree) {
        for node in tree.rootNode.namedChildren {
            switch node.type {
            case "package_declaration":
                packageDeclarationEnd = node.endByte
                packageName = node.text
                    .replacingOccurrences(of: #"^\s*package\s+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s*;\s*$"#, with: "", options: .regularExpression)
                    .filter { !$0.isWhitespace }
            case "import_declaration":
                let raw = node.text
                let isStatic = raw.range(of: #"^import\s+static\b"#, options: .regularExpression) != nil
                let isOnDemand = raw.contains("*")
                let name = raw
                    .replacingOccurrences(of: #"^import\s+(static\s+)?"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s*(\.\s*\*)?\s*;\s*$"#, with: "", options: .regularExpression)
                    .filter { !$0.isWhitespace }
                entries.append(JavaImportEntry(
                    qualifiedName: name, isStatic: isStatic, isOnDemand: isOnDemand, range: node.byteRange
                ))
            default:
                break
            }
        }
    }
}
