import Foundation
import LanguageSyntax
import TreeSitterKotlin

/// JUnit declarations with an unambiguous annotation and a JVM class owner.
enum KotlinJVMTestDiscovery {
    private static let annotations: [String: JavaTestFramework] = [
        "org.junit.Test": .junit4,
        "org.junit.jupiter.api.Test": .junit5,
        "org.junit.jupiter.api.RepeatedTest": .junit5,
        "org.junit.jupiter.api.TestFactory": .junit5,
        "org.junit.jupiter.params.ParameterizedTest": .junit5
    ]

    static func discover(source: String, url: URL) -> [String: [JavaTestMethod]] {
        guard let tree = SyntaxParser(language: tree_sitter_kotlin()).parse(source) else { return [:] }
        let root = tree.rootNode
        let package = root.namedChildren.first { $0.type == "package_header" }?.namedChild(at: 0)?.text ?? ""
        let imports = root.namedChildren.filter { $0.type == "import_list" || $0.type == "import_header" }
            .flatMap { $0.type == "import_list" ? $0.namedChildren : [$0] }
            .map { $0.text.dropFirst("import".count).trimmingCharacters(in: .whitespacesAndNewlines) }
        var result: [String: [JavaTestMethod]] = [:]

        func visitClasses(in container: SyntaxNode, parents: [String]) {
            for type in container.namedChildren where type.type == "class_declaration" {
                guard let name = type.namedChildren.first(where: { $0.type == "type_identifier" })?.text,
                      let body = type.namedChildren.first(where: { $0.type == "class_body" }) else { continue }
                let ancestry = parents + [name]
                let binary = ancestry.joined(separator: "$")
                let qualified = package.isEmpty ? binary : package + "." + binary
                for function in body.namedChildren where function.type == "function_declaration" {
                    guard let method = function.namedChildren.first(where: { $0.type == "simple_identifier" }),
                          let modifiers = function.namedChildren.first(where: { $0.type == "modifiers" }),
                          let framework = modifiers.namedChildren.lazy.filter({ $0.type == "annotation" })
                            .compactMap({ annotationFramework($0.text, imports: imports) }).first else { continue }
                    let position = JavaTestDiscovery.lineColumn(forByteOffset: method.startByte, in: tree.sourceBytes)
                    let methodName = method.text.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                    guard !methodName.contains("*") else { continue }
                    result[qualified, default: []].append(JavaTestMethod(
                        className: qualified, methodName: methodName, displayName: methodName, sourceFile: url,
                        line: position.line + 1, column: position.column, framework: framework
                    ))
                }
                visitClasses(in: body, parents: ancestry)
            }
        }
        visitClasses(in: root, parents: [])
        return result
    }

    private static func annotationFramework(_ text: String, imports: [String]) -> JavaTestFramework? {
        let name = String(text.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" })
        if let framework = annotations[name] { return framework }
        let explicit = imports.compactMap { entry -> String? in
            let parts = entry.components(separatedBy: " as ")
            if let alias = parts.dropFirst().first { return alias == name ? parts[0] : nil }
            return entry.split(separator: ".").last.map(String.init) == name ? entry : nil
        }
        if explicit.count == 1 { return annotations[explicit[0]] }
        guard explicit.isEmpty else { return nil }
        let candidates = imports.filter { $0.hasSuffix(".*") }.map { String($0.dropLast()) + name }
        let known = candidates.compactMap { annotations[$0] }
        return known.count == 1 ? known[0] : nil
    }
}
