import EditorIntelligence
import Foundation

private let commentTypes: Set<String> = ["line_comment", "block_comment"]

private func arguments(of call: SyntaxNode) -> [SyntaxNode] {
    (call.child(byFieldName: "arguments")?.namedChildren ?? []).filter { !commentTypes.contains($0.type) }
}

private func literalContent(_ literal: SyntaxNode) -> String? {
    guard literal.type == "string_literal", literal.text.count >= 2 else { return nil }
    return String(literal.text.dropFirst().dropLast())
}

/// The operands of a `a + b + c` chain.
private func concatenationOperands(_ node: SyntaxNode) -> [SyntaxNode] {
    let inner = node.unparenthesized
    guard inner.type == "binary_expression", inner.operatorText == "+",
          let left = inner.child(byFieldName: "left"), let right = inner.child(byFieldName: "right") else { return [inner] }
    return concatenationOperands(left) + concatenationOperands(right)
}

private let constantTypes: Set<String> = [
    "string_literal", "decimal_integer_literal", "hex_integer_literal", "decimal_floating_point_literal",
    "character_literal", "true", "false", "null_literal",
]

/// A concatenation of literal text and at least one value that is not a literal.
private func isInjectable(_ node: SyntaxNode) -> (text: String, variable: SyntaxNode)? {
    let operands = concatenationOperands(node)
    guard operands.count > 1 else { return nil }
    let text = operands.compactMap { $0.type == "string_literal" ? literalContent($0) : nil }.joined(separator: " ")
    guard !text.isEmpty, let variable = operands.first(where: { !constantTypes.contains($0.type) }) else { return nil }
    return (text, variable)
}

enum JavaWeakCryptographicAlgorithmInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.weakCryptographicAlgorithm
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let weakDigests: Set<String> = ["MD2", "MD4", "MD5", "SHA-1", "SHA1", "SHA"]
    private static let weakCiphers: Set<String> = ["DES", "DESEDE", "TRIPLEDES", "RC2", "RC4", "ARCFOUR"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.child(byFieldName: "name")?.text == "getInstance", let owner = node.child(byFieldName: "object")?.text,
              let first = arguments(of: node).first, let content = literalContent(first) else { return }
        let upper = content.uppercased()
        var problem: String?
        switch owner {
        case "MessageDigest":
            if weakDigests.contains(upper) { problem = "The hash algorithm '\(content)' is broken" }
        case "Cipher":
            let parts = upper.split(separator: "/").map(String.init)
            if let algorithm = parts.first, weakCiphers.contains(algorithm) {
                problem = "The cipher '\(content)' is weak"
            } else if parts.count >= 2, parts[1] == "ECB" {
                problem = "ECB mode in '\(content)' leaks patterns in the data"
            } else if parts.count == 1, parts[0] == "AES" || parts[0] == "RSA" {
                problem = parts[0] == "AES" ? "'AES' without a mode defaults to ECB" : nil
            }
        default:
            break
        }
        guard let problem else { return }
        report(JavaInspectionSupport.inspection(rule, message: problem, node: first))
    }
}

enum JavaSqlStringConcatenationInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.sqlStringConcatenation
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let methods: Set<String> = [
        "executeQuery", "executeUpdate", "execute", "executeLargeUpdate", "prepareStatement", "prepareCall", "addBatch",
        "createNativeQuery", "createQuery",
    ]
    private static let sqlWord = try! NSRegularExpression(
        pattern: #"\b(select|insert|update|delete|from|where|create|drop|alter|exec|union)\b"#, options: .caseInsensitive
    )

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name")?.text, methods.contains(name),
              let first = arguments(of: node).first, let found = isInjectable(first) else { return }
        let range = NSRange(location: 0, length: (found.text as NSString).length)
        guard sqlWord.firstMatch(in: found.text, range: range) != nil else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "The query passed to '\(name)' is built with '\(found.variable.text)': use a parameter instead", node: first
        ))
    }
}

enum JavaRuntimeExecConcatenationInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.runtimeExecConcatenation
    static let nodeTypes: Set<String> = ["method_invocation"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.child(byFieldName: "name")?.text == "exec", let object = node.child(byFieldName: "object"),
              object.text == "Runtime.getRuntime()" || (object.type == "identifier" && JavaDeclaredTypes.type(of: object)?.name == "Runtime"),
              let first = arguments(of: node).first, let found = isInjectable(first) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "The command is built with '\(found.variable.text)': pass the arguments as an array", node: first
        ))
    }
}

/// `String password = "hunter2";`
enum JavaHardcodedCredentialInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.hardcodedCredential
    static let nodeTypes: Set<String> = ["variable_declarator"]
    private static let words = ["password", "passwd", "pwd", "secret", "apikey", "api_key", "privatekey", "private_key"]
    private static let notACredential = [
        "name", "prop", "property", "header", "field", "label", "prompt", "env", "pattern", "regex", "msg", "message", "text",
        "title", "id", "path", "file", "url", "uri", "type", "hint", "error", "param", "parameter", "attribute", "attr",
        "column", "claim", "cookie", "placeholder", "keyname", "key",
    ]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name"), let value = node.child(byFieldName: "value"),
              let content = literalContent(value), !content.isEmpty else { return }
        let lowered = name.text.lowercased()
        guard words.contains(where: lowered.contains), !notACredential.contains(where: lowered.hasSuffix) else { return }
        // `PASSWORD = "password"` names a key, it does not hold a credential.
        let valueText = content.lowercased()
        guard !words.contains(where: valueText.contains), !content.contains(" ") else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'\(name.text)' is initialized with a hard-coded credential", node: value
        ))
    }
}
