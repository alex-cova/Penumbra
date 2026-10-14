import EditorIntelligence
import Foundation

/// The nearest enclosing class body that declares a field `name`, and whether that field is volatile.
private func fieldVolatility(of name: String, at node: SyntaxNode) -> (body: SyntaxNode, isVolatile: Bool)? {
    var current = node.parent
    while let scope = current {
        if scope.type == "class_body", let isVolatile = node.tree.declarationCache.fieldVolatility(of: scope)[name] {
            return (scope, isVolatile)
        }
        current = scope.parent
    }
    return nil
}

/// Whether `node` sits in a `synchronized` method or block of its own member.
private func isInsideSynchronizedCode(_ node: SyntaxNode) -> Bool {
    var current = node.parent
    while let scope = current {
        switch scope.type {
        case "synchronized_statement":
            return true
        case "method_declaration":
            return scope.hasModifier("synchronized")
        case "constructor_declaration", "class_body", "static_initializer":
            return false
        default:
            break
        }
        current = scope.parent
    }
    return false
}

/// A private helper (called with the caller's lock held) or a member that takes a `Lock` itself.
private func isGuardedByExplicitLock(_ node: SyntaxNode) -> Bool {
    var current = node.parent
    while let scope = current {
        if scope.type == "method_declaration" || scope.type == "constructor_declaration" {
            if scope.hasModifier("private") { return true }
            var locks = false
            scope.forEachDescendant { candidate in
                guard candidate.type == "method_invocation", let name = candidate.child(byFieldName: "name")?.text else { return }
                if ["lock", "lockInterruptibly", "tryLock", "readLock", "writeLock"].contains(name) { locks = true }
            }
            return locks
        }
        if scope.type == "class_body" || scope.type == "static_initializer" { return false }
        current = scope.parent
    }
    return false
}

/// `count++` and `count += 1` on a volatile field.
enum JavaVolatileNonAtomicUpdateInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.volatileNonAtomicUpdate
    static let nodeTypes: Set<String> = ["update_expression", "assignment_expression"]

    private static func fieldName(of target: SyntaxNode, context: JavaInspectionContext) -> String? {
        let inner = target.unparenthesized
        switch inner.type {
        case "identifier":
            let symbols = context.tree.declarationCache.fileSymbols(context: context)
            return symbols.localIdentifiers.contains(inner.byteRange) ? nil : inner.text
        case "field_access":
            guard inner.child(byFieldName: "object")?.type == "this" else { return nil }
            return inner.child(byFieldName: "field")?.text
        default:
            return nil
        }
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        let target: SyntaxNode?
        if node.type == "update_expression" {
            target = node.namedChild(at: 0)
        } else {
            guard let op = node.operatorText, let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right")
            else { return }
            if op == "=" {
                // `x = x + 1`: the value read in the right-hand side is the field itself.
                // A parameter or local of the same name (`this.x = x`) is not a read of the field.
                var reads = false
                let symbols = context.tree.declarationCache.fileSymbols(context: context)
                let name = left.unparenthesized.type == "field_access" ? left.unparenthesized.child(byFieldName: "field")?.text : left.text
                func readsField(_ candidate: SyntaxNode) -> Bool {
                    if candidate.type == "identifier" {
                        // `src.locale` and `locale()` name a member of something else, not this class's field.
                        if let parent = candidate.parent,
                           parent.type == "field_access" || parent.type == "method_invocation",
                           parent.child(byFieldName: parent.type == "field_access" ? "field" : "name")?.byteRange == candidate.byteRange {
                            return false
                        }
                        return candidate.text == name && !symbols.localIdentifiers.contains(candidate.byteRange)
                    }
                    if candidate.type == "field_access", candidate.child(byFieldName: "object")?.type == "this" {
                        return candidate.child(byFieldName: "field")?.text == name
                    }
                    return false
                }
                if readsField(right) { reads = true }
                right.forEachDescendant { if readsField($0) { reads = true } }
                guard reads else { return }
            }
            target = left
        }
        guard let target, let name = fieldName(of: target, context: context),
              let field = fieldVolatility(of: name, at: node), field.isVolatile, !isInsideSynchronizedCode(node),
              !isGuardedByExplicitLock(node) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Non-atomic update of volatile field '\(name)': concurrent updates can be lost", node: node
        ))
    }
}

/// `wait()` / `notify()` without holding the receiver's monitor.
enum JavaWaitNotifyOutsideSynchronizedInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.waitNotifyOutsideSynchronized
    static let nodeTypes: Set<String> = ["method_invocation"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name")?.text, ["wait", "notify", "notifyAll"].contains(name),
              let arguments = node.child(byFieldName: "arguments"), arguments.namedChildCount <= (name == "wait" ? 2 : 0) else { return }
        let object = node.child(byFieldName: "object")
        let lockText: String
        if let object {
            guard object.type == "this" || object.type == "identifier" || object.type == "field_access" else { return }
            lockText = object.text
        } else {
            lockText = "this"
        }
        var current = node.parent
        while let scope = current {
            switch scope.type {
            case "synchronized_statement":
                if let held = scope.namedChild(at: 0)?.unparenthesized.text, held == lockText { return }
            case "method_declaration":
                // A synchronized method holds `this`; a private helper is usually called with the lock held.
                if lockText == "this", scope.hasModifier("synchronized") { return }
                if scope.hasModifier("private") { return }
                report(JavaInspectionSupport.inspection(
                    rule, message: "'\(name)()' is called without holding the monitor of '\(lockText)'", node: node
                ))
                return
            case "constructor_declaration", "class_body", "static_initializer":
                report(JavaInspectionSupport.inspection(
                    rule, message: "'\(name)()' is called without holding the monitor of '\(lockText)'", node: node
                ))
                return
            default:
                break
            }
            current = scope.parent
        }
    }
}

/// `private static SimpleDateFormat FORMAT = …`.
enum JavaStaticNonThreadSafeFormatInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.staticNonThreadSafeFormat
    static let nodeTypes: Set<String> = ["field_declaration"]
    private static let unsafe: Set<String> = ["SimpleDateFormat", "DateFormat", "NumberFormat", "DecimalFormat", "Calendar", "GregorianCalendar"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.hasModifier("static"), let type = node.child(byFieldName: "type") else { return }
        let simple = JavaDeclaredTypes.simpleName(of: type)
        guard unsafe.contains(simple) else { return }
        for declarator in node.namedChildren(ofType: "variable_declarator") {
            guard let name = declarator.child(byFieldName: "name") else { continue }
            report(JavaInspectionSupport.inspection(
                rule, message: "'\(simple)' is not thread-safe: the static field '\(name.text)' shares one instance between threads", node: name
            ))
        }
    }
}

/// `if (x == null) { synchronized (…) { if (x == null) { x = …; } } }` with a non-volatile `x`.
enum JavaDoubleCheckedLockingInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.doubleCheckedLocking
    static let nodeTypes: Set<String> = ["if_statement"]

    /// The field a `x == null` / `this.x == null` condition tests.
    private static func testedField(_ condition: SyntaxNode?) -> String? {
        guard let inner = condition?.unparenthesized, inner.type == "binary_expression", inner.operatorText == "==",
              let left = inner.child(byFieldName: "left"), let right = inner.child(byFieldName: "right"),
              right.type == "null_literal" else { return nil }
        switch left.type {
        case "identifier": return left.text
        case "field_access":
            return left.child(byFieldName: "object")?.type == "this" ? left.child(byFieldName: "field")?.text : nil
        default: return nil
        }
    }

    private static func assigns(_ name: String, in block: SyntaxNode) -> Bool {
        var found = false
        block.forEachDescendant { node in
            guard node.type == "assignment_expression", node.operatorText == "=", let left = node.child(byFieldName: "left") else { return }
            if left.text == name || left.text == "this.\(name)" { found = true }
        }
        return found
    }

    private static func match(_ node: SyntaxNode) -> (name: String, body: SyntaxNode)? {
        guard let name = testedField(node.child(byFieldName: "condition")),
              let consequence = node.child(byFieldName: "consequence") else { return nil }
        let synchronizedBlocks = (consequence.type == "block" ? consequence.namedChildren : [consequence])
            .filter { $0.type == "synchronized_statement" }
        for lock in synchronizedBlocks {
            guard let body = lock.child(byFieldName: "body") else { continue }
            for inner in body.namedChildren where inner.type == "if_statement" {
                guard testedField(inner.child(byFieldName: "condition")) == name,
                      let assigned = inner.child(byFieldName: "consequence"), assigns(name, in: assigned) else { continue }
                guard let field = fieldVolatility(of: name, at: node), !field.isVolatile else { return nil }
                return (name, field.body)
            }
        }
        return nil
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let found = match(node) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Double-checked locking on '\(found.name)' is broken unless the field is volatile", node: node,
            fixTitle: "Make '\(found.name)' volatile"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "if_statement", for: diagnostic, tree: tree, source: source),
              let found = match(node) else { return [] }
        for member in found.body.namedChildren where member.type == "field_declaration" {
            let declares = member.namedChildren(ofType: "variable_declarator").contains {
                $0.child(byFieldName: "name")?.text == found.name
            }
            guard declares, let type = member.child(byFieldName: "type") else { continue }
            let edit = JavaInspectionSupport.edit(replacingBytes: type.startByte..<type.startByte, with: "volatile ", in: tree)
            return [CodeAction(title: "Make '\(found.name)' volatile", kind: "quickfix", edits: [edit], isPreferred: true)]
        }
        return []
    }
}
