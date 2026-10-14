import EditorIntelligence
import Foundation

private let commentTypes: Set<String> = ["line_comment", "block_comment"]

/// A package declaration the file's directory does not end with.
enum JavaPackageDirectoryMismatchInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.packageDirectoryMismatch
    static let nodeTypes: Set<String> = ["program"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let declaration = node.firstNamedChild(ofType: "package_declaration"),
              let name = declaration.namedChildren.first(where: { $0.type == "scoped_identifier" || $0.type == "identifier" }) else { return }
        let directory = context.url.standardizedFileURL.deletingLastPathComponent().path
        let expected = "/" + name.text.split(separator: ".").joined(separator: "/")
        // A scratch buffer has no directory worth comparing.
        // `snippet-files` holds the JDK's Javadoc snippets, which declare the package they illustrate.
        guard !directory.hasPrefix("/unsaved"), !directory.hasSuffix(expected), directory != "/",
              (directory as NSString).lastPathComponent != "snippet-files" else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Package '\(name.text)' does not match the directory '\((directory as NSString).lastPathComponent)'", node: name
        ))
    }
}

/// `notify()`.
enum JavaNotifyInsteadOfNotifyAllInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.notifyInsteadOfNotifyAll
    static let nodeTypes: Set<String> = ["method_invocation"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name"), name.text == "notify",
              node.child(byFieldName: "arguments")?.namedChildCount == 0 else { return }
        if let object = node.child(byFieldName: "object"), !["this", "identifier", "field_access"].contains(object.type) { return }
        report(JavaInspectionSupport.inspection(rule, message: "'notify()' wakes only one waiter; consider 'notifyAll()'", node: name))
    }
}

/// `thread.stop()`, `Thread.currentThread().suspend()`.
enum JavaUnsafeThreadMethodInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.unsafeThreadMethod
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let unsafe: Set<String> = ["stop", "suspend", "resume", "destroy"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name"), unsafe.contains(name.text),
              let object = node.child(byFieldName: "object"), let arguments = node.child(byFieldName: "arguments"),
              arguments.namedChildCount <= (name.text == "stop" ? 1 : 0) else { return }
        let isThread: Bool
        switch object.type {
        case "identifier", "field_access":
            let type = JavaDeclaredTypes.type(of: object)
            isThread = type?.name == "Thread" && type?.isArray == false
        case "method_invocation":
            isThread = object.text == "Thread.currentThread()"
        case "object_creation_expression":
            isThread = object.child(byFieldName: "type")?.text == "Thread"
        default:
            isThread = false
        }
        guard isThread else { return }
        report(JavaInspectionSupport.inspection(rule, message: "'Thread.\(name.text)()' is unsafe and deprecated", node: name))
    }
}

/// `private volatile int[] data;`
enum JavaVolatileArrayFieldInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.volatileArrayField
    static let nodeTypes: Set<String> = ["field_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.hasModifier("volatile") else { return }
        let typeIsArray = node.child(byFieldName: "type")?.type == "array_type"
        for declarator in node.namedChildren(ofType: "variable_declarator") {
            guard typeIsArray || declarator.child(byFieldName: "dimensions") != nil,
                  let name = declarator.child(byFieldName: "name") else { continue }
            report(JavaInspectionSupport.inspection(
                rule, message: "'\(name.text)' is a volatile array: its elements are not volatile", node: name
            ))
        }
    }
}

/// `public Object clone() { return new Foo(this); }`
enum JavaCloneWithoutSuperCallInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.cloneWithoutSuperCall
    static let nodeTypes: Set<String> = ["method_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name"), name.text == "clone",
              node.child(byFieldName: "parameters")?.namedChildCount == 0,
              let body = node.child(byFieldName: "body"), !node.hasModifier("static"), !node.hasModifier("final") else { return }
        // A final class has no subclass whose clone() could come back as the wrong type.
        var owner = node.parent
        while let scope = owner, scope.type != "class_declaration", scope.type != "object_creation_expression" { owner = scope.parent }
        if let owner, owner.type == "class_declaration", owner.hasModifier("final") || owner.type == "record_declaration" { return }
        var callsSuper = false
        var throwsInstead = false
        body.forEachDescendant { candidate in
            if candidate.type == "method_invocation", candidate.child(byFieldName: "name")?.text == "clone",
               candidate.child(byFieldName: "object")?.type == "super" { callsSuper = true }
            if candidate.type == "throw_statement" { throwsInstead = true }
        }
        guard !callsSuper, !throwsInstead else { return }
        report(JavaInspectionSupport.inspection(rule, message: "'clone()' does not call 'super.clone()'", node: name))
    }
}

/// `equals(Object o)` that casts `o` with no `instanceof` or `getClass()` test.
enum JavaEqualsWithoutTypeCheckInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.equalsWithoutTypeCheck
    static let nodeTypes: Set<String> = ["method_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name"), name.text == "equals",
              let parameters = node.child(byFieldName: "parameters"), parameters.namedChildCount == 1,
              let parameter = parameters.namedChild(at: 0), parameter.child(byFieldName: "type")?.text == "Object",
              let argument = parameter.child(byFieldName: "name")?.text,
              let body = node.child(byFieldName: "body") else { return }
        var casts = false
        var checksType = false
        body.forEachDescendant { candidate in
            if candidate.type == "cast_expression", candidate.child(byFieldName: "value")?.unparenthesized.text == argument { casts = true }
            if candidate.type == "instanceof_expression" { checksType = true }
            guard candidate.type == "method_invocation", let called = candidate.child(byFieldName: "name")?.text else { return }
            if called == "getClass" { checksType = true }
            // `sameClassAs(obj)`, `canEqual(obj)`, `type.isInstance(obj)`: a helper that does the test.
            if called != "equals", candidate.child(byFieldName: "arguments")?.namedChildren
                .contains(where: { $0.type == "identifier" && $0.text == argument }) == true { checksType = true }
        }
        guard casts, !checksType else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'equals()' casts '\(argument)' without checking its type first", node: name
        ))
    }
}

/// `public String toString() { return null; }`
enum JavaToStringReturnsNullInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.toStringReturnsNull
    static let nodeTypes: Set<String> = ["return_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let value = node.namedChild(at: 0), value.type == "null_literal" else { return }
        var current = node.parent
        while let scope = current {
            if scope.type == "lambda_expression" || scope.type == "class_body" { return }
            if scope.type == "method_declaration" {
                guard scope.child(byFieldName: "name")?.text == "toString",
                      scope.child(byFieldName: "parameters")?.namedChildCount == 0 else { return }
                report(JavaInspectionSupport.inspection(rule, message: "'toString()' returns null", node: node))
                return
            }
            current = scope.parent
        }
    }
}

/// `System.exit(1)`, `Runtime.getRuntime().halt(1)`.
enum JavaSystemExitCallInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.systemExitCall
    static let nodeTypes: Set<String> = ["method_invocation"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name")?.text, let object = node.child(byFieldName: "object") else { return }
        let isExit = object.text == "System" && name == "exit"
        let isHalt = object.text == "Runtime.getRuntime()" && (name == "exit" || name == "halt")
        guard isExit || isHalt else { return }
        report(JavaInspectionSupport.inspection(rule, message: "'\(object.text).\(name)()' shuts the whole JVM down", node: node))
    }
}

/// `int mode = 0644;`
enum JavaOctalLiteralInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.octalLiteral
    static let nodeTypes: Set<String> = ["octal_integer_literal"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        let digits = node.text.replacingOccurrences(of: "_", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "lL"))
        guard digits.count > 1, digits.allSatisfy(\.isNumber) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'\(node.text)' is an octal literal (decimal \(Int(digits, radix: 8).map(String.init) ?? "?"))", node: node
        ))
    }
}

/// A method parameter named like a field of its class.
enum JavaParameterHidesFieldInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.parameterHidesField
    static let nodeTypes: Set<String> = ["method_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let method = node.child(byFieldName: "name")?.text, !method.hasPrefix("set"), !method.hasPrefix("with"),
              !node.hasModifier("static"), let body = node.parent, body.type == "class_body",
              let parameters = node.child(byFieldName: "parameters") else { return }
        let fields = node.tree.declarationCache.fieldFlags(of: body)
        guard !fields.isEmpty else { return }
        for parameter in parameters.namedChildren where parameter.type == "formal_parameter" {
            guard let name = parameter.child(byFieldName: "name"), fields[name.text] != nil else { continue }
            report(JavaInspectionSupport.inspection(rule, message: "Parameter '\(name.text)' hides the field '\(name.text)'", node: name))
        }
    }
}

/// `count = 0;` where `count` is a non-final static field, in an instance method.
enum JavaStaticFieldWrittenFromInstanceInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.staticFieldWrittenFromInstance
    static let nodeTypes: Set<String> = ["assignment_expression", "update_expression"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        let target = node.type == "update_expression" ? node.namedChild(at: 0) : node.child(byFieldName: "left")
        guard let name = target?.unparenthesized, name.type == "identifier" else { return }
        var current = node.parent
        var inInstanceMethod = false
        var body: SyntaxNode?
        while let scope = current {
            if scope.type == "lambda_expression" { break }
            if scope.type == "method_declaration" || scope.type == "constructor_declaration" {
                inInstanceMethod = scope.type == "constructor_declaration" ? false : !scope.hasModifier("static")
                body = scope.parent
                break
            }
            if scope.type == "class_body" { return }
            current = scope.parent
        }
        guard inInstanceMethod, let body, body.type == "class_body",
              let flags = node.tree.declarationCache.fieldFlags(of: body)[name.text], flags.isStatic, !flags.isFinal else { return }
        let symbols = node.tree.declarationCache.fileSymbols(context: context)
        guard !symbols.localIdentifiers.contains(name.byteRange) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Static field '\(name.text)' is written from an instance method", node: node
        ))
    }
}
