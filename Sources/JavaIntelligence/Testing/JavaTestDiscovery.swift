import Foundation

/// Finds JUnit 4/5 test methods in a parsed Java source file.
public enum JavaTestDiscovery {
    private static let declarationTypes: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration",
        "record_declaration", "annotation_type_declaration"
    ]

    private static let junit5SimpleNames: Set<String> = [
        "Test", "ParameterizedTest", "RepeatedTest", "TestFactory"
    ]

    private static let junit5QualifiedNames: Set<String> = [
        "org.junit.jupiter.api.Test",
        "org.junit.jupiter.api.ParameterizedTest",
        "org.junit.jupiter.api.RepeatedTest",
        "org.junit.jupiter.api.TestFactory"
    ]

    private static let junit4QualifiedName = "org.junit.Test"

    /// Parses `source` and returns test methods grouped by their declaring type's qualified name.
    public static func discover(source: String, url: URL) -> [String: [JavaTestMethod]] {
        guard let tree = JavaSyntaxParser().parse(source) else { return [:] }
        return discover(tree: tree, url: url)
    }

    public static func discover(tree: JavaSyntaxTree, url: URL) -> [String: [JavaTestMethod]] {
        let importList = JavaImportList(tree: tree)
        var byClass: [String: [JavaTestMethod]] = [:]
        walk(node: tree.rootNode, packageName: importList.packageName, url: url, importList: importList, into: &byClass)
        return byClass
    }

    private static func walk(
        node: SyntaxNode,
        packageName: String,
        url: URL,
        importList: JavaImportList,
        into result: inout [String: [JavaTestMethod]]
    ) {
        if node.type == "method_declaration" {
            if let method = parseTestMethod(node, packageName: packageName, url: url, importList: importList) {
                result[method.className, default: []].append(method)
            }
            return
        }
        for child in node.namedChildren {
            walk(node: child, packageName: packageName, url: url, importList: importList, into: &result)
        }
    }

    private static func parseTestMethod(
        _ node: SyntaxNode,
        packageName: String,
        url: URL,
        importList: JavaImportList
    ) -> JavaTestMethod? {
        guard let nameNode = node.child(byFieldName: "name") else { return nil }
        guard let framework = testFramework(in: node, importList: importList) else { return nil }
        guard let className = enclosingQualifiedTypeName(of: node, packageName: packageName) else { return nil }
        let position = lineColumn(forByteOffset: nameNode.startByte, in: node.tree.sourceBytes)
        return JavaTestMethod(
            className: className,
            methodName: nameNode.text,
            displayName: nameNode.text,
            sourceFile: url.standardizedFileURL,
            line: position.line + 1,
            column: position.column,
            framework: framework
        )
    }

    private static func testFramework(in method: SyntaxNode, importList: JavaImportList) -> JavaTestFramework? {
        guard let modifiers = method.namedChildren.first(where: { $0.type == "modifiers" }) else { return nil }
        for annotation in modifiers.namedChildren where annotation.type == "marker_annotation" || annotation.type == "annotation" {
            let name = annotationSimpleName(annotation)
            if let framework = classifyAnnotation(name, importList: importList) {
                return framework
            }
        }
        return nil
    }

    private static func annotationSimpleName(_ node: SyntaxNode) -> String {
        if let name = node.child(byFieldName: "name") {
            return dottedName(name)
        }
        guard let first = node.namedChild(at: 0) else { return "" }
        return dottedName(first)
    }

    private static func dottedName(_ node: SyntaxNode) -> String {
        switch node.type {
        case "identifier", "type_identifier":
            return node.text
        case "scoped_identifier":
            return node.namedChildren.map(\.text).joined(separator: ".")
        default:
            return node.text
        }
    }

    private static func classifyAnnotation(_ name: String, importList: JavaImportList) -> JavaTestFramework? {
        if junit5QualifiedNames.contains(name) { return .junit5 }
        if name == junit4QualifiedName { return .junit4 }
        if name == "Test" {
            if importList.entries.contains(where: { !$0.isStatic && $0.qualifiedName == junit4QualifiedName }) {
                return .junit4
            }
            if importList.entries.contains(where: { !$0.isStatic && isJunit5Import($0, simpleName: "Test") }) {
                return .junit5
            }
            // Bare `@Test` with no conflicting import: treat as JUnit 5 (modern default).
            if !importList.entries.contains(where: { !$0.isStatic && $0.qualifiedName.split(separator: ".").last == "Test" && $0.qualifiedName != "org.junit.jupiter.api.Test" }) {
                return .junit5
            }
        }
        if junit5SimpleNames.contains(name), importList.entries.contains(where: { !$0.isStatic && isJunit5Import($0, simpleName: name) }) {
            return .junit5
        }
        if name.split(separator: ".").last.map(String.init) == "Test", name.hasPrefix("org.junit.jupiter") {
            return .junit5
        }
        return nil
    }

    private static func isJunit5Import(_ entry: JavaImportEntry, simpleName: String) -> Bool {
        if entry.isOnDemand { return entry.qualifiedName == "org.junit.jupiter.api" }
        return entry.qualifiedName == "org.junit.jupiter.api.\(simpleName)"
    }

    private static func enclosingQualifiedTypeName(of node: SyntaxNode, packageName: String) -> String? {
        var names: [String] = []
        var current = node.parent
        while let parent = current {
            if declarationTypes.contains(parent.type), let name = parent.child(byFieldName: "name") {
                names.insert(name.text, at: 0)
            }
            current = parent.parent
        }
        guard !names.isEmpty else { return nil }
        let nested = names.joined(separator: ".")
        if packageName.isEmpty { return nested }
        return "\(packageName).\(nested)"
    }

    private static func lineColumn(forByteOffset byteOffset: Int, in bytes: [UInt8]) -> (line: Int, column: Int) {
        let clamped = min(max(0, byteOffset), bytes.count)
        var line = 0
        var lineStart = 0
        for index in 0..<clamped where bytes[index] == 10 {
            line += 1
            lineStart = index + 1
        }
        let lineText = String(decoding: bytes[lineStart..<clamped], as: UTF8.self)
        return (line, lineText.utf16.count)
    }
}
