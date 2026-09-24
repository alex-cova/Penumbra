import Foundation

/// Finds JUnit 4/5 test classes and methods in one Java file by walking its tree-sitter tree.
/// Annotation names resolve against the file's imports; see ``scan(tree:url:frameworks:)``.
public enum JavaTestScanner {
    private enum Role {
        case test(JavaTestMethodKind), nested, disabled, displayName, runWith
    }

    private struct Known {
        let qualifiedName: String
        let framework: JavaTestFramework
        let role: Role

        var simpleName: String { String(qualifiedName.split(separator: ".").last ?? "") }
        var packageName: String { String(qualifiedName.dropLast(simpleName.count + 1)) }
    }

    private static let known: [Known] = [
        Known(qualifiedName: "org.junit.jupiter.api.Test", framework: .junit5, role: .test(.test)),
        Known(qualifiedName: "org.junit.jupiter.params.ParameterizedTest", framework: .junit5, role: .test(.parameterized)),
        Known(qualifiedName: "org.junit.jupiter.api.RepeatedTest", framework: .junit5, role: .test(.repeated)),
        Known(qualifiedName: "org.junit.jupiter.api.TestFactory", framework: .junit5, role: .test(.factory)),
        Known(qualifiedName: "org.junit.jupiter.api.TestTemplate", framework: .junit5, role: .test(.template)),
        Known(qualifiedName: "org.junit.jupiter.api.Nested", framework: .junit5, role: .nested),
        Known(qualifiedName: "org.junit.jupiter.api.Disabled", framework: .junit5, role: .disabled),
        Known(qualifiedName: "org.junit.jupiter.api.DisplayName", framework: .junit5, role: .displayName),
        Known(qualifiedName: "org.junit.Test", framework: .junit4, role: .test(.test)),
        Known(qualifiedName: "org.junit.Ignore", framework: .junit4, role: .disabled),
        Known(qualifiedName: "org.junit.runner.RunWith", framework: .junit4, role: .runWith)
    ]

    public static func scan(source: String, url: URL, frameworks: Set<JavaTestFramework>) -> [JavaTestClass] {
        guard let tree = JavaSyntaxParser().parse(source) else { return [] }
        return scan(tree: tree, url: url, frameworks: frameworks)
    }

    /// - Parameter frameworks: the frameworks on the source set's classpath. A simple annotation
    ///   name with no matching explicit import (same-package or unresolvable) is accepted only for
    ///   these; an explicit or on-demand import of the JUnit package is always accepted.
    public static func scan(tree: JavaSyntaxTree, url: URL, frameworks: Set<JavaTestFramework>) -> [JavaTestClass] {
        let stubs = JavaSourceStubBuilder.build(tree: tree, url: url)
        let resolver = Resolver(imports: stubs.imports, frameworks: frameworks)
        var declarations: [ClassInfo] = []
        for node in tree.rootNode.namedChildren where node.type == "class_declaration" {
            collect(node, outerQualified: nil, outerBinary: nil, package: stubs.packageName, resolver: resolver, into: &declarations)
        }
        let bySimpleName = Dictionary(declarations.map { ($0.simpleName, $0) }, uniquingKeysWith: { first, _ in first })

        var result: [JavaTestClass] = []
        for info in declarations {
            var methods = info.ownMethods
            var seen = Set(methods.map(\.name))
            var visited: Set<String> = [info.simpleName]
            var current = info.superName
            while let name = current, !visited.contains(name), let base = bySimpleName[name] {
                visited.insert(name)
                for method in base.ownMethods where !seen.contains(method.name) {
                    seen.insert(method.name)
                    methods.append(JavaTestMethod(
                        name: method.name, nameRange: method.nameRange, kind: method.kind, displayName: method.displayName,
                        isDisabled: method.isDisabled, framework: method.framework, inheritedFrom: base.simpleName
                    ))
                }
                current = base.superName
            }
            guard !methods.isEmpty else { continue }
            methods.sort { (a, b) in
                let ai = a.inheritedFrom == nil ? 0 : 1, bi = b.inheritedFrom == nil ? 0 : 1
                return ai != bi ? ai < bi : a.nameRange.lowerBound < b.nameRange.lowerBound
            }
            result.append(JavaTestClass(
                simpleName: info.simpleName, qualifiedName: info.qualifiedName, binaryName: info.binaryName,
                nameRange: info.nameRange, displayName: info.displayName, isNested: info.isNested,
                isAbstract: info.isAbstract, isDisabled: info.isDisabled, framework: methods[0].framework,
                runner: info.runner, methods: methods
            ))
        }
        return result
    }

    // MARK: Walk

    private struct ClassInfo {
        var simpleName: String
        var qualifiedName: String
        var binaryName: String
        var nameRange: Range<Int>
        var displayName: String
        var isNested: Bool
        var isAbstract: Bool
        var isDisabled: Bool
        var runner: String?
        var superName: String?
        var ownMethods: [JavaTestMethod]
    }

    private static func collect(
        _ node: SyntaxNode, outerQualified: String?, outerBinary: String?, package: String,
        resolver: Resolver, into result: inout [ClassInfo]
    ) {
        guard let nameNode = node.child(byFieldName: "name") else { return }
        let simple = nameNode.text
        let qualified = outerQualified.map { "\($0).\(simple)" } ?? (package.isEmpty ? simple : "\(package).\(simple)")
        let binary = outerBinary.map { "\($0)$\(simple)" } ?? qualified

        let found = annotations(of: node, resolver: resolver)
        var superName: String?
        if let superType = node.child(byFieldName: "superclass")?.namedChildren.first {
            var text = superType.text
            if let angle = text.firstIndex(of: "<") { text = String(text[..<angle]) }
            superName = text.split(separator: ".").last.map(String.init)
        }
        let modifiers = node.namedChildren.first { $0.type == "modifiers" }
        let isAbstract = modifiers?.children.contains { $0.type == "abstract" } ?? false

        var methods: [JavaTestMethod] = []
        var nested: [SyntaxNode] = []
        for member in node.child(byFieldName: "body")?.namedChildren ?? [] {
            switch member.type {
            case "method_declaration":
                if let method = testMethod(member, resolver: resolver) { methods.append(method) }
            case "class_declaration":
                nested.append(member)
            default:
                break
            }
        }

        result.append(ClassInfo(
            simpleName: simple, qualifiedName: qualified, binaryName: binary, nameRange: nameNode.byteRange,
            displayName: found.displayName ?? simple, isNested: outerQualified != nil, isAbstract: isAbstract,
            isDisabled: found.isDisabled, runner: found.runner, superName: superName, ownMethods: methods
        ))
        for inner in nested {
            collect(inner, outerQualified: qualified, outerBinary: binary, package: package, resolver: resolver, into: &result)
        }
    }

    private static func testMethod(_ node: SyntaxNode, resolver: Resolver) -> JavaTestMethod? {
        guard let nameNode = node.child(byFieldName: "name") else { return nil }
        let modifiers = node.namedChildren.first { $0.type == "modifiers" }
        if modifiers?.children.contains(where: { $0.type == "private" }) == true { return nil }
        let found = annotations(of: node, resolver: resolver)
        guard let kind = found.testKind, let framework = found.testFramework else { return nil }
        return JavaTestMethod(
            name: nameNode.text, nameRange: nameNode.byteRange, kind: kind,
            displayName: found.displayName ?? nameNode.text, isDisabled: found.isDisabled, framework: framework
        )
    }

    private struct Found {
        var testKind: JavaTestMethodKind?
        var testFramework: JavaTestFramework?
        var isDisabled = false
        var displayName: String?
        var runner: String?
    }

    private static func annotations(of node: SyntaxNode, resolver: Resolver) -> Found {
        var found = Found()
        guard let modifiers = node.namedChildren.first(where: { $0.type == "modifiers" }) else { return found }
        for annotation in modifiers.children where annotation.type == "annotation" || annotation.type == "marker_annotation" {
            guard let name = annotation.child(byFieldName: "name")?.text, let hit = resolver.resolve(name) else { continue }
            switch hit.role {
            case .test(let kind):
                // JUnit 5 wins when both a 4 and a 5 annotation somehow apply.
                if found.testKind == nil || hit.framework == .junit5 {
                    found.testKind = kind
                    found.testFramework = hit.framework
                }
            case .nested:
                break
            case .disabled:
                found.isDisabled = true
            case .displayName:
                found.displayName = firstStringArgument(annotation)
            case .runWith:
                found.runner = annotation.child(byFieldName: "arguments").map {
                    $0.text.trimmingCharacters(in: CharacterSet(charactersIn: "() "))
                }
            }
        }
        return found
    }

    private static func firstStringArgument(_ annotation: SyntaxNode) -> String? {
        guard var value = annotation.child(byFieldName: "arguments")?.namedChildren.first else { return nil }
        if value.type == "element_value_pair", let inner = value.child(byFieldName: "value") { value = inner }
        guard value.type == "string_literal" else { return nil }
        let text = value.text
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return nil }
        return String(text.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    // MARK: Name resolution

    private struct Resolver {
        let imports: [JavaImportDeclaration]
        let frameworks: Set<JavaTestFramework>

        func resolve(_ written: String) -> Known? {
            if written.contains(".") {
                return known.first { $0.qualifiedName == written }
            }
            let candidates = known.filter { $0.simpleName == written }
            guard !candidates.isEmpty else { return nil }
            // An explicit single-type import decides, even when it names some other library's type.
            if let explicit = imports.first(where: { !$0.isStatic && !$0.isOnDemand && $0.qualifiedName.split(separator: ".").last.map(String.init) == written }) {
                return candidates.first { $0.qualifiedName == explicit.qualifiedName }
            }
            let onDemand = Set(imports.filter { !$0.isStatic && $0.isOnDemand }.map(\.qualifiedName))
            let viaOnDemand = candidates.filter { onDemand.contains($0.packageName) }
            if let hit = viaOnDemand.first(where: { $0.framework == .junit5 }) ?? viaOnDemand.first { return hit }
            // Unresolvable: trust the simple name only for a framework on the classpath.
            return candidates.first { $0.framework == .junit5 && frameworks.contains(.junit5) }
                ?? candidates.first { frameworks.contains($0.framework) }
        }
    }
}
