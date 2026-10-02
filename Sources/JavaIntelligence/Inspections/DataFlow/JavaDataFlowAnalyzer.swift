import Foundation

extension JavaInspectionRunner {
    static let flowRules = Set(JavaInspectionRegistry.flowRules)

    /// Runs the data-flow rules: each method, constructor, initializer and lambda body is interpreted once.
    static func runFlow(context: JavaInspectionContext, enabled: Set<JavaInspectionRule>) -> [JavaInspection] {
        JavaDataFlowAnalyzer.run(context: context, enabled: enabled.intersection(flowRules))
    }
}

/// An abstract interpreter over one method body. It follows the structured control flow of Java
/// (no jumps other than `break` / `continue` / `return` / `throw`), keeps what is known about each
/// local, and reports only what holds on every path to a statement. Anything it does not follow
/// (loops, `try`, lambdas, switch expressions) makes the affected locals unknown instead of
/// guessing, so a silent result is always an acceptable answer.
///
/// A `nil` state means the point cannot complete normally, which is also javac's reachability
/// rule; a branch that only the facts rule out (`if (x == null)` where `x` is known non-null) is
/// still run, with the other side's state and its findings muted, so that the two notions of
/// "unreachable" stay apart.
final class JavaDataFlowAnalyzer {
    private struct Condition {
        /// The state when the condition holds; nil when the facts rule that out.
        var whenTrue: JavaFlowState?
        var whenFalse: JavaFlowState?
    }

    private final class Frame {
        let label: String?
        let isLoop: Bool
        let isSwitch: Bool
        var breaks: JavaFlowState?
        var broken = false
        var continued = false

        init(label: String? = nil, isLoop: Bool = false, isSwitch: Bool = false) {
            self.label = label
            self.isLoop = isLoop
            self.isSwitch = isSwitch
        }
    }

    private let context: JavaInspectionContext
    private let table: JavaFileSymbolTable
    private let enabled: Set<JavaInspectionRule>
    private(set) var findings: [JavaInspection] = []
    private(set) var aborted = false
    private var reported = Set<String>()
    private var frames: [Frame] = []
    private var steps = 0
    private var depth = 0
    private var muted = 0
    /// Inside a `try` with `finally`: a `return` there may be followed by cleanup the analysis does not see.
    private var protectedExits = 0
    private var resourceNodes: [Int: SyntaxNode] = [:]
    private var leaksReported = Set<Int>()

    private static let maxSteps = 300_000
    private static let maxDepth = 150
    private static let comments: Set<String> = ["line_comment", "block_comment"]
    private static let closeableTypes: Set<String> = [
        "FileInputStream", "FileOutputStream", "FileReader", "FileWriter", "BufferedReader", "BufferedWriter", "BufferedInputStream",
        "BufferedOutputStream", "InputStreamReader", "OutputStreamWriter", "ObjectInputStream", "ObjectOutputStream", "DataInputStream",
        "DataOutputStream", "Scanner", "Socket", "ServerSocket", "RandomAccessFile", "ZipFile", "JarFile", "ZipInputStream",
        "ZipOutputStream", "GZIPInputStream", "GZIPOutputStream",
    ]

    private init(context: JavaInspectionContext, table: JavaFileSymbolTable, enabled: Set<JavaInspectionRule>) {
        self.context = context
        self.table = table
        self.enabled = enabled
    }

    // MARK: Entry

    static func run(context: JavaInspectionContext, enabled: Set<JavaInspectionRule>) -> [JavaInspection] {
        guard !enabled.isEmpty else { return [] }
        let table = context.tree.declarationCache.fileSymbols(context: context)
        var results: [JavaInspection] = []
        var stack = [context.tree.rootNode]
        while let node = stack.popLast() {
            if let body = rootBody(of: node) {
                let analyzer = JavaDataFlowAnalyzer(context: context, table: table, enabled: enabled)
                analyzer.analyze(body: body)
                if !analyzer.aborted { results.append(contentsOf: analyzer.findings) }
            }
            stack.append(contentsOf: node.namedChildren)
        }
        return results
    }

    private static func rootBody(of node: SyntaxNode) -> SyntaxNode? {
        switch node.type {
        case "method_declaration", "constructor_declaration", "compact_constructor_declaration":
            return node.child(byFieldName: "body")
        case "lambda_expression":
            guard let body = node.child(byFieldName: "body"), body.type == "block" else { return nil }
            return body
        case "static_initializer":
            return node.firstNamedChild(ofType: "block")
        case "block":
            return node.parent?.type == "class_body" ? node : nil
        default:
            return nil
        }
    }

    private func analyze(body: SyntaxNode) {
        // Parameters start unknown: an annotation such as @NotNull is a promise, and defensive checks against it are deliberate.
        let state = JavaFlowState()
        if let end = execStatements(body.namedChildren, state) {
            checkLeaks(in: end)
            recordExit(end)
        }
        reportDeadStores()
    }

    // MARK: Reporting

    private func report(_ rule: JavaInspectionRule, _ message: String, at node: SyntaxNode, severity: JavaInspection.Severity? = nil, isFact: Bool = true) {
        guard enabled.contains(rule), !isFact || muted == 0, reported.insert("\(rule.code)@\(node.startByte)").inserted else { return }
        var inspection = JavaInspectionSupport.inspection(rule, message: message, node: node)
        if let severity { inspection = inspection.withSeverity(severity) }
        findings.append(inspection)
    }

    private func tick() {
        steps += 1
        if steps > Self.maxSteps || depth > Self.maxDepth { aborted = true }
    }

    private func key(of identifier: SyntaxNode) -> Int? {
        table.localOfUse[identifier.byteRange]?.lowerBound
    }

    private func isLocalIdentifier(_ node: SyntaxNode) -> Int? {
        let inner = node.unparenthesized
        return inner.type == "identifier" ? key(of: inner) : nil
    }

    // MARK: Subtree summaries

    /// The locals assigned anywhere under `node`, and every local mentioned there.
    private func summary(of node: SyntaxNode) -> (assigned: Set<Int>, used: Set<Int>) {
        var assigned = Set<Int>()
        var used = Set<Int>()
        var stack = [node]
        while let current = stack.popLast() {
            switch current.type {
            case "identifier":
                if let key = key(of: current) { used.insert(key) }
            case "assignment_expression":
                if let left = current.child(byFieldName: "left"), let key = isLocalIdentifier(left) { assigned.insert(key) }
            case "update_expression":
                if let operand = current.namedChild(at: 0), let key = isLocalIdentifier(operand) { assigned.insert(key) }
            default:
                break
            }
            stack.append(contentsOf: current.namedChildren)
        }
        return (assigned, used)
    }

    /// Forget the assigned locals, and stop tracking resources that the subtree touches.
    private func widened(_ state: JavaFlowState, for node: SyntaxNode) -> JavaFlowState {
        let (assigned, used) = summary(of: node)
        return clearingResources(forget(state, assigned), keys: used)
    }

    private func clearingResources(_ state: JavaFlowState, keys: Set<Int>) -> JavaFlowState {
        var copy = state
        for key in keys {
            if copy.values[key]?.resource != JavaResourceState.none { copy.values[key]?.resource = JavaResourceState.none }
            // A loop, handler or closure that mentions the local may read it: its stores are no longer provably dead.
            if let stores = copy.unread.removeValue(forKey: key) { liveStores.formUnion(stores) }
        }
        return copy
    }

    private func hasLocal(_ node: SyntaxNode) -> Bool {
        var stack = [node]
        while let current = stack.popLast() {
            if current.type == "identifier", key(of: current) != nil { return true }
            stack.append(contentsOf: current.namedChildren)
        }
        return false
    }

    // MARK: Merging

    /// Joins the outcomes of alternative paths. A path the facts rule out does not contribute its
    /// state, but if it could complete, the result still can (as an unknown state).
    private func merge(_ outcomes: [(state: JavaFlowState?, feasible: Bool)]) -> JavaFlowState? {
        var joined: JavaFlowState?
        var completes = false
        for outcome in outcomes {
            guard let state = outcome.state else { continue }
            completes = true
            if outcome.feasible { joined = JavaFlowState.join(joined, state) }
        }
        if let joined { return joined }
        return completes ? JavaFlowState() : nil
    }

    private func execMuted(_ node: SyntaxNode, _ state: JavaFlowState, muted isMuted: Bool) -> JavaFlowState? {
        if isMuted { muted += 1 }
        defer { if isMuted { muted -= 1 } }
        return exec(node, state)
    }

    // MARK: Statements

    private func execStatements(_ nodes: [SyntaxNode], _ state: JavaFlowState) -> JavaFlowState? {
        var current: JavaFlowState? = state
        var flaggedUnreachable = false
        for statement in nodes where !Self.comments.contains(statement.type) {
            guard let live = current else {
                if !flaggedUnreachable {
                    flaggedUnreachable = true
                    report(.unreachableCode, "Unreachable statement", at: statement, isFact: false)
                }
                continue
            }
            current = exec(statement, live)
            if aborted { return nil }
        }
        return current
    }

    private func exec(_ node: SyntaxNode, _ state: JavaFlowState) -> JavaFlowState? {
        tick()
        guard !aborted else { return nil }
        depth += 1
        defer { depth -= 1 }
        switch node.type {
        case "block":
            return execStatements(node.namedChildren, state)
        case "expression_statement":
            var next = state
            for child in node.namedChildren { _ = eval(child, &next) }
            return next
        case "local_variable_declaration":
            var next = state
            execDeclaration(node, &next)
            return next
        case "if_statement":
            return execIf(node, state)
        case "while_statement":
            return execWhile(node, state)
        case "do_statement":
            return execDo(node, state)
        case "for_statement":
            return execFor(node, state)
        case "enhanced_for_statement":
            return execForEach(node, state)
        case "switch_expression", "switch_statement":
            return execSwitch(node, state)
        case "try_statement", "try_with_resources_statement":
            return execTry(node, state)
        case "synchronized_statement":
            var next = state
            if let lock = node.firstNamedChild(ofType: "parenthesized_expression") { receiver(lock, &next) }
            guard let body = node.child(byFieldName: "body") else { return next }
            return exec(body, next)
        case "labeled_statement":
            let label = node.firstNamedChild(ofType: "identifier")?.text
            guard let inner = node.namedChildren.last(where: { $0.type != "identifier" && !Self.comments.contains($0.type) }) else { return state }
            let frame = Frame(label: label)
            frames.append(frame)
            let out = exec(inner, state)
            frames.removeLast()
            return merge([(out, true), (frame.breaks, frame.broken)])
        case "return_statement":
            var next = state
            for child in node.namedChildren { _ = eval(child, &next) }
            if protectedExits == 0 {
                checkLeaks(in: next)
                recordExit(next)
            } else {
                // A `finally` may still read it.
                var cleared = next
                cleared.unread = [:]
                recordExit(cleared)
            }
            return nil
        case "throw_statement", "yield_statement":
            var next = state
            for child in node.namedChildren { _ = eval(child, &next) }
            return nil
        case "break_statement":
            let label = node.firstNamedChild(ofType: "identifier")?.text
            let target = label != nil ? frames.last { $0.label == label } : frames.last { $0.isLoop || $0.isSwitch }
            if let target {
                target.broken = true
                target.breaks = JavaFlowState.join(target.breaks, state)
            }
            return nil
        case "continue_statement":
            let label = node.firstNamedChild(ofType: "identifier")?.text
            if label == nil {
                frames.last { $0.isLoop }?.continued = true
            } else {
                for frame in frames where frame.isLoop { frame.continued = true }
            }
            return nil
        case "assert_statement":
            var scratch = state
            for child in node.namedChildren { _ = eval(child, &scratch) }
            return state
        case "explicit_constructor_invocation":
            var next = state
            for child in node.namedChildren { _ = eval(child, &next) }
            return next
        case "class_declaration", "interface_declaration", "enum_declaration", "record_declaration":
            return state
        default:
            var next = state
            for child in node.namedChildren where !Self.comments.contains(child.type) { _ = eval(child, &next) }
            return next
        }
    }

    private func execDeclaration(_ node: SyntaxNode, _ state: inout JavaFlowState) {
        for declarator in node.namedChildren(ofType: "variable_declarator") {
            guard let name = declarator.child(byFieldName: "name") else { continue }
            let key = name.startByte
            guard let value = declarator.child(byFieldName: "value") else {
                state.values.removeValue(forKey: key)
                state.unread.removeValue(forKey: key)
                continue
            }
            var result = eval(value, &state)
            result.resource = JavaResourceState.none
            if isCloseableCreation(value) {
                result.resource = .open
                resourceNodes[key] = name
            }
            state.values[key] = result
            recordStore(key: key, name: name.text, value: value, isInitializer: true, &state)
        }
    }

    private func execIf(_ node: SyntaxNode, _ state: JavaFlowState) -> JavaFlowState? {
        guard let conditionNode = node.child(byFieldName: "condition"), let consequence = node.child(byFieldName: "consequence") else { return state }
        let c = cond(conditionNode, state)
        let thenOut = execMuted(consequence, c.whenTrue ?? c.whenFalse ?? state, muted: c.whenTrue == nil)
        let elseOut: JavaFlowState?
        if let alternative = node.child(byFieldName: "alternative") {
            elseOut = execMuted(alternative, c.whenFalse ?? c.whenTrue ?? state, muted: c.whenFalse == nil)
        } else {
            elseOut = c.whenFalse ?? JavaFlowState()
        }
        return merge([(thenOut, c.whenTrue != nil), (elseOut, c.whenFalse != nil)])
    }

    private func isInfinite(_ condition: SyntaxNode?) -> Bool {
        guard let condition else { return true }
        return condition.unparenthesized.type == "true"
    }

    private func execWhile(_ node: SyntaxNode, _ state: JavaFlowState) -> JavaFlowState? {
        guard let conditionNode = node.child(byFieldName: "condition"), let body = node.child(byFieldName: "body") else { return state }
        let head = widened(state, for: node)
        let c = cond(conditionNode, head)
        let frame = Frame(isLoop: true)
        frames.append(frame)
        _ = execMuted(body, c.whenTrue ?? c.whenFalse ?? head, muted: c.whenTrue == nil)
        frames.removeLast()
        var outcomes: [(state: JavaFlowState?, feasible: Bool)] = []
        if !isInfinite(conditionNode) { outcomes.append((c.whenFalse ?? head, c.whenFalse != nil)) }
        outcomes.append((frame.breaks, frame.broken))
        return merge(outcomes)
    }

    private func execDo(_ node: SyntaxNode, _ state: JavaFlowState) -> JavaFlowState? {
        guard let conditionNode = node.child(byFieldName: "condition"), let body = node.child(byFieldName: "body") else { return state }
        let head = widened(state, for: node)
        let frame = Frame(isLoop: true)
        frames.append(frame)
        let bodyOut = exec(body, head)
        frames.removeLast()
        var outcomes: [(state: JavaFlowState?, feasible: Bool)] = []
        if let conditionState = bodyOut ?? (frame.continued ? head : nil) {
            let c = cond(conditionNode, conditionState)
            if !isInfinite(conditionNode) { outcomes.append((c.whenFalse ?? conditionState, c.whenFalse != nil)) }
        }
        outcomes.append((frame.breaks, frame.broken))
        return merge(outcomes)
    }

    private func execFor(_ node: SyntaxNode, _ state: JavaFlowState) -> JavaFlowState? {
        guard let body = node.child(byFieldName: "body") else { return state }
        // The header has three sections separated by `;`; `child(byFieldName:)` only returns the first node of a section.
        var sections: [[SyntaxNode]] = [[], [], []]
        var section = 0
        for child in node.children {
            if child.startByte >= body.startByte { break }
            if child.type == ";" { section = min(section + 1, 2); continue }
            guard child.isNamed, !Self.comments.contains(child.type) else { continue }
            sections[section].append(child)
            // A declaration carries its own `;`, which ends the init section.
            if section == 0, child.type == "local_variable_declaration" { section = 1 }
        }
        var entry = state
        for initializer in sections[0] {
            if initializer.type == "local_variable_declaration" { execDeclaration(initializer, &entry) } else { _ = eval(initializer, &entry) }
        }
        let head = widened(entry, for: node)
        let conditionNode = sections[1].first
        let c = conditionNode.map { cond($0, head) } ?? Condition(whenTrue: head, whenFalse: nil)
        let frame = Frame(isLoop: true)
        frames.append(frame)
        _ = execMuted(body, c.whenTrue ?? c.whenFalse ?? head, muted: c.whenTrue == nil)
        frames.removeLast()
        var outcomes: [(state: JavaFlowState?, feasible: Bool)] = []
        if !isInfinite(conditionNode) { outcomes.append((c.whenFalse ?? head, c.whenFalse != nil)) }
        outcomes.append((frame.breaks, frame.broken))
        return merge(outcomes)
    }

    private func execForEach(_ node: SyntaxNode, _ state: JavaFlowState) -> JavaFlowState? {
        guard let body = node.child(byFieldName: "body") else { return state }
        var entry = state
        if let value = node.child(byFieldName: "value") { receiver(value, &entry) }
        var head = widened(entry, for: node)
        if let name = node.child(byFieldName: "name") { head.values.removeValue(forKey: name.startByte) }
        let frame = Frame(isLoop: true)
        frames.append(frame)
        _ = exec(body, head)
        frames.removeLast()
        return merge([(head, true), (frame.breaks, frame.broken)])
    }

    private func execSwitch(_ node: SyntaxNode, _ state: JavaFlowState) -> JavaFlowState? {
        var entry = state
        if let selector = node.child(byFieldName: "condition") { receiver(selector, &entry) }
        guard let block = node.child(byFieldName: "body") else { return entry }
        let frame = Frame(isSwitch: true)
        frames.append(frame)
        var hasDefault = false
        var outcomes: [(state: JavaFlowState?, feasible: Bool)] = []
        let members = block.namedChildren.filter { !Self.comments.contains($0.type) }
        if members.contains(where: { $0.type == "switch_rule" }) {
            for rule in members where rule.type == "switch_rule" {
                if rule.firstNamedChild(ofType: "switch_label")?.text.contains("default") == true { hasDefault = true }
                guard let body = rule.namedChildren.last(where: { $0.type != "switch_label" && !Self.comments.contains($0.type) }) else {
                    outcomes.append((entry, true))
                    continue
                }
                outcomes.append((exec(body, entry), true))
            }
        } else {
            var fallThrough: JavaFlowState?
            for group in members where group.type == "switch_block_statement_group" {
                if group.namedChildren(ofType: "switch_label").contains(where: { $0.text.contains("default") }) { hasDefault = true }
                let groupEntry = fallThrough.map { entry.joined(with: $0) } ?? entry
                fallThrough = execStatements(group.namedChildren.filter { $0.type != "switch_label" }, groupEntry)
            }
            outcomes.append((fallThrough, true))
        }
        frames.removeLast()
        if !hasDefault { outcomes.append((entry, true)) }
        outcomes.append((frame.breaks, frame.broken))
        return merge(outcomes)
    }

    private func execTry(_ node: SyntaxNode, _ state: JavaFlowState) -> JavaFlowState? {
        var entry = state
        if let resources = node.child(byFieldName: "resources") {
            for resource in resources.namedChildren(ofType: "resource") {
                if let value = resource.child(byFieldName: "value") { _ = eval(value, &entry) }
            }
        }
        let finallyBlock = node.firstNamedChild(ofType: "finally_clause")?.firstNamedChild(ofType: "block")
        let isProtected = finallyBlock != nil || node.type == "try_with_resources_statement"
        guard let body = node.child(byFieldName: "body") else { return entry }
        let tryEffects = summary(of: body)
        let catches = node.namedChildren(ofType: "catch_clause")
        var exceptional = Set<Int>()
        exceptional.formUnion(tryEffects.assigned)
        var catchEffectsAssigned = Set<Int>()
        for clause in catches { catchEffectsAssigned.formUnion(summary(of: clause).assigned) }
        if isProtected { protectedExits += 1 }
        var outcomes: [(state: JavaFlowState?, feasible: Bool)] = [(exec(body, entry), true)]
        // An exception can leave the body after any statement, so what the body assigns or closes is unknown in a handler.
        let handlerEntry = clearingResources(forget(entry, exceptional), keys: tryEffects.used)
        for clause in catches {
            var catchEntry = handlerEntry
            if let parameter = clause.firstNamedChild(ofType: "catch_formal_parameter")?.child(byFieldName: "name") {
                catchEntry.values[parameter.startByte] = JavaFlowValue(nullness: .nonNull)
            }
            if let catchBody = clause.child(byFieldName: "body") { outcomes.append((exec(catchBody, catchEntry), true)) }
        }
        if isProtected { protectedExits -= 1 }
        let merged = merge(outcomes)
        guard let finallyBlock else { return merged }
        // Findings come from a run on the cautious entry state; the state after the statement from a run on the merged one.
        let finallyEntry = clearingResources(forget(entry, exceptional.union(catchEffectsAssigned)), keys: tryEffects.used)
        guard exec(finallyBlock, finallyEntry) != nil else { return nil }
        guard let merged else { return nil }
        muted += 1
        defer { muted -= 1 }
        return exec(finallyBlock, merged)
    }

    // MARK: Resources

    private func isCloseableCreation(_ node: SyntaxNode) -> Bool {
        let inner = node.unparenthesized
        guard inner.type == "object_creation_expression", inner.firstNamedChild(ofType: "class_body") == nil,
              let type = inner.child(byFieldName: "type") else { return false }
        let name = JavaDeclaredTypes.simpleName(of: type)
        guard Self.closeableTypes.contains(name) else { return false }
        // `new Scanner(System.in)` must not be closed.
        if name == "Scanner", inner.child(byFieldName: "arguments")?.text.contains("System.in") == true { return false }
        return true
    }

    /// A store is dead when some path overwrites it or leaves the method without reading it and
    /// no path reads it. Reads and anything the analysis stops following make a store live.
    private var liveStores = Set<JavaPendingStore>()
    private var overwrittenStores = Set<JavaPendingStore>()
    private var unreadAtExit = Set<JavaPendingStore>()

    private func recordExit(_ state: JavaFlowState) {
        guard muted == 0 else { return }
        for stores in state.unread.values { unreadAtExit.formUnion(stores) }
    }

    private func reportDeadStores() {
        guard enabled.contains(.unusedAssignment) else { return }
        let candidates = overwrittenStores.union(unreadAtExit.filter { !$0.isInitializer }).subtracting(liveStores)
        for store in candidates.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            let message = overwrittenStores.contains(store)
                ? "The value assigned to '\(store.name)' is overwritten before it is used"
                : "The value assigned to '\(store.name)' is never used"
            guard reported.insert("\(JavaInspectionRule.unusedAssignment.code)@\(store.range.lowerBound)").inserted else { continue }
            findings.append(JavaInspectionSupport.inspection(
                .unusedAssignment, message: message, startByte: store.range.lowerBound, endByte: store.range.upperBound, tree: context.tree
            ))
        }
    }

    private func markRead(_ key: Int, _ state: inout JavaFlowState) {
        if let stores = state.unread.removeValue(forKey: key) { liveStores.formUnion(stores) }
    }

    private func recordStore(key: Int, name: String, value: SyntaxNode, isInitializer: Bool, _ state: inout JavaFlowState) {
        if muted == 0, let previous = state.unread[key] { overwrittenStores.formUnion(previous) }
        state.unread[key] = [JavaPendingStore(range: value.byteRange, name: name, isInitializer: isInitializer)]
    }

    /// Forgets the locals' values and pending stores; the stores count as live since nobody follows them.
    private func forget(_ state: JavaFlowState, _ keys: Set<Int>) -> JavaFlowState {
        for key in keys { if let stores = state.unread[key] { liveStores.formUnion(stores) } }
        return state.havoc(keys)
    }

    private func checkLeaks(in state: JavaFlowState) {
        guard enabled.contains(.resourceNotClosed), muted == 0 else { return }
        for (key, value) in state.values where value.resource == .open || value.resource == .mixed {
            guard let node = resourceNodes[key], leaksReported.insert(key).inserted else { continue }
            let message = value.resource == .open
                ? "Resource '\(node.text)' is not closed"
                : "Resource '\(node.text)' is not closed on every path"
            report(.resourceNotClosed, message, at: node)
        }
    }

    // MARK: Conditions

    private func describe(_ node: SyntaxNode) -> String {
        let text = node.text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        return text.count > 60 ? String(text.prefix(57)) + "..." : text
    }

    private func reportConstant(_ node: SyntaxNode, _ value: Bool, isNullCheck: Bool) {
        let rule: JavaInspectionRule = isNullCheck ? .redundantNullCheck : .constantConditionFlow
        report(rule, "Condition '\(describe(node))' is always \(value)", at: node)
    }

    private func cond(_ raw: SyntaxNode, _ state: JavaFlowState) -> Condition {
        tick()
        guard !aborted else { return Condition(whenTrue: state, whenFalse: state) }
        depth += 1
        defer { depth -= 1 }
        let node = raw.unparenthesized
        switch node.type {
        case "true":
            return Condition(whenTrue: state, whenFalse: nil)
        case "false":
            return Condition(whenTrue: nil, whenFalse: state)
        case "unary_expression":
            if node.text.hasPrefix("!"), let operand = node.namedChild(at: 0) {
                let inner = cond(operand, state)
                return Condition(whenTrue: inner.whenFalse, whenFalse: inner.whenTrue)
            }
        case "binary_expression":
            if let result = binaryCondition(node, state) { return result }
        case "instanceof_expression":
            var scratch = state
            guard let left = node.child(byFieldName: "left") else { break }
            if let key = isLocalIdentifier(left) {
                markRead(key, &scratch)
                var narrowed = scratch
                narrowed.values[key, default: JavaFlowValue()].nullness = .nonNull
                return Condition(whenTrue: narrowed, whenFalse: scratch)
            }
            _ = eval(left, &scratch)
            return Condition(whenTrue: scratch, whenFalse: scratch)
        default:
            break
        }
        var scratch = state
        let value = eval(node, &scratch)
        if case .bool(let result)? = value.constant {
            if hasLocal(node) { reportConstant(node, result, isNullCheck: false) }
            return result ? Condition(whenTrue: scratch, whenFalse: nil) : Condition(whenTrue: nil, whenFalse: scratch)
        }
        return Condition(whenTrue: scratch, whenFalse: scratch)
    }

    private func binaryCondition(_ node: SyntaxNode, _ state: JavaFlowState) -> Condition? {
        guard let op = node.operatorText, let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right") else { return nil }
        switch op {
        case "&&":
            let a = cond(left, state)
            guard let afterLeft = a.whenTrue else { return Condition(whenTrue: nil, whenFalse: a.whenFalse) }
            let b = cond(right, afterLeft)
            return Condition(whenTrue: b.whenTrue, whenFalse: JavaFlowState.join(a.whenFalse, b.whenFalse))
        case "||":
            let a = cond(left, state)
            guard let afterLeft = a.whenFalse else { return Condition(whenTrue: a.whenTrue, whenFalse: nil) }
            let b = cond(right, afterLeft)
            return Condition(whenTrue: JavaFlowState.join(a.whenTrue, b.whenTrue), whenFalse: b.whenFalse)
        case "==", "!=":
            let isEquality = op == "=="
            let leftIsNull = left.unparenthesized.type == "null_literal"
            let rightIsNull = right.unparenthesized.type == "null_literal"
            guard leftIsNull != rightIsNull else { return comparison(node, op: op, left: left, right: right, state) }
            return nullCheck(node, subject: leftIsNull ? right : left, isEquality: isEquality, state)
        case "<", ">", "<=", ">=":
            return comparison(node, op: op, left: left, right: right, state)
        default:
            return nil
        }
    }

    private func nullCheck(_ node: SyntaxNode, subject: SyntaxNode, isEquality: Bool, _ state: JavaFlowState) -> Condition {
        var scratch = state
        var target = subject.unparenthesized
        // `(line = reader.readLine()) != null`: run the assignment, then judge the variable.
        if target.type == "assignment_expression", target.operatorText == "=", let left = target.child(byFieldName: "left"), left.type == "identifier" {
            _ = eval(target, &scratch)
            target = left
        }
        guard target.type == "identifier", let key = key(of: target) else {
            _ = eval(target, &scratch)
            return Condition(whenTrue: scratch, whenFalse: scratch)
        }
        markRead(key, &scratch)
        let known = scratch.values[key]?.nullness ?? .unknown
        var nullState = scratch
        nullState.values[key, default: JavaFlowValue()].nullness = .null
        nullState.values[key]?.constant = nil
        var nonNullState = scratch
        nonNullState.values[key, default: JavaFlowValue()].nullness = .nonNull
        switch known {
        case .null:
            reportConstant(node, isEquality, isNullCheck: true)
            return isEquality ? Condition(whenTrue: nullState, whenFalse: nil) : Condition(whenTrue: nil, whenFalse: nullState)
        case .nonNull:
            reportConstant(node, !isEquality, isNullCheck: true)
            return isEquality ? Condition(whenTrue: nil, whenFalse: nonNullState) : Condition(whenTrue: nonNullState, whenFalse: nil)
        default:
            return isEquality ? Condition(whenTrue: nullState, whenFalse: nonNullState) : Condition(whenTrue: nonNullState, whenFalse: nullState)
        }
    }

    private func comparison(_ node: SyntaxNode, op: String, left: SyntaxNode, right: SyntaxNode, _ state: JavaFlowState) -> Condition {
        var scratch = state
        let a = eval(left, &scratch)
        let b = eval(right, &scratch)
        if let result = Self.fold(op, a.constant, b.constant) {
            if hasLocal(node) { reportConstant(node, result, isNullCheck: false) }
            return result ? Condition(whenTrue: scratch, whenFalse: nil) : Condition(whenTrue: nil, whenFalse: scratch)
        }
        return Condition(whenTrue: scratch, whenFalse: scratch)
    }

    private static func fold(_ op: String, _ a: JavaFlowConstant?, _ b: JavaFlowConstant?) -> Bool? {
        switch (a, b) {
        case (.int(let x)?, .int(let y)?):
            switch op {
            case "==": return x == y
            case "!=": return x != y
            case "<": return x < y
            case ">": return x > y
            case "<=": return x <= y
            case ">=": return x >= y
            default: return nil
            }
        case (.bool(let x)?, .bool(let y)?):
            switch op {
            case "==": return x == y
            case "!=": return x != y
            default: return nil
            }
        default:
            return nil
        }
    }

    // MARK: Expressions

    /// Evaluates a receiver (`x.f`, `x.m()`, `x[i]`, a `for` source): a null local there is a bug.
    private func receiver(_ raw: SyntaxNode, _ state: inout JavaFlowState) {
        let node = raw.unparenthesized
        guard node.type == "identifier", let key = key(of: node) else {
            _ = eval(node, &state)
            return
        }
        markRead(key, &state)
        guard let value = state.values[key] else { return }
        switch value.nullness {
        case .null:
            report(.nullDereference, "Variable '\(node.text)' is always null here: this throws a NullPointerException", at: node, severity: .error)
        case .nullable:
            report(.nullableDereference, "Variable '\(node.text)' may be null here", at: node)
        default:
            break
        }
        state.values[key]?.nullness = .nonNull
    }

    private func intLiteral(_ text: String) -> Int? {
        let digits = text.replacingOccurrences(of: "_", with: "")
        guard let value = Int(digits), value <= Int(Int32.max) else { return nil }
        return value
    }

    private func eval(_ node: SyntaxNode, _ state: inout JavaFlowState) -> JavaFlowValue {
        tick()
        guard !aborted else { return JavaFlowValue() }
        depth += 1
        defer { depth -= 1 }
        switch node.type {
        case "null_literal":
            return JavaFlowValue(nullness: .null)
        case "string_literal", "character_literal", "text_block", "floating_point_literal", "decimal_floating_point_literal":
            return JavaFlowValue(nullness: .nonNull)
        case "true":
            return JavaFlowValue(nullness: .nonNull, constant: .bool(true))
        case "false":
            return JavaFlowValue(nullness: .nonNull, constant: .bool(false))
        case "decimal_integer_literal":
            return JavaFlowValue(nullness: .nonNull, constant: intLiteral(node.text).map { .int($0) })
        case "parenthesized_expression":
            guard let inner = node.namedChild(at: 0) else { return JavaFlowValue() }
            return eval(inner, &state)
        case "identifier":
            if let key = key(of: node) { markRead(key, &state) }
            guard let key = key(of: node), var value = state.values[key] else { return JavaFlowValue() }
            // Used as a value: it may be stored or passed on, so nobody can say it is still ours to close.
            state.values[key]?.resource = JavaResourceState.none
            value.resource = JavaResourceState.none
            return value
        case "assignment_expression":
            return evalAssignment(node, &state)
        case "update_expression":
            if let operand = node.namedChild(at: 0), let key = isLocalIdentifier(operand) {
                markRead(key, &state)
                state.values.removeValue(forKey: key)
            } else if let operand = node.namedChild(at: 0) {
                _ = eval(operand, &state)
            }
            return JavaFlowValue()
        case "method_invocation":
            return evalInvocation(node, &state)
        case "field_access":
            if let object = node.child(byFieldName: "object") { receiver(object, &state) }
            return JavaFlowValue()
        case "array_access":
            if let array = node.child(byFieldName: "array") { receiver(array, &state) }
            if let index = node.child(byFieldName: "index") { _ = eval(index, &state) }
            return JavaFlowValue()
        case "object_creation_expression":
            for child in node.namedChildren {
                if child.type == "class_body" {
                    state = clearingResources(state, keys: summary(of: child).used)
                } else if child.type != "type_identifier", child.type != "generic_type", child.type != "scoped_type_identifier" {
                    _ = eval(child, &state)
                }
            }
            return JavaFlowValue(nullness: .nonNull)
        case "argument_list", "array_initializer", "dimensions_expr", "array_creation_expression", "element_value_array_initializer":
            for child in node.namedChildren { _ = eval(child, &state) }
            return node.type == "array_creation_expression" ? JavaFlowValue(nullness: .nonNull) : JavaFlowValue()
        case "binary_expression":
            return evalBinary(node, &state)
        case "unary_expression":
            guard let operand = node.namedChild(at: 0) else { return JavaFlowValue() }
            let value = eval(operand, &state)
            if node.text.hasPrefix("!"), case .bool(let b)? = value.constant { return JavaFlowValue(nullness: .nonNull, constant: .bool(!b)) }
            if node.text.hasPrefix("-"), case .int(let n)? = value.constant { return JavaFlowValue(nullness: .nonNull, constant: .int(-n)) }
            return JavaFlowValue()
        case "ternary_expression":
            guard let condition = node.child(byFieldName: "condition"), let yes = node.child(byFieldName: "consequence"),
                  let no = node.child(byFieldName: "alternative") else { return JavaFlowValue() }
            let c = cond(condition, state)
            var yesState = c.whenTrue ?? c.whenFalse ?? state
            var noState = c.whenFalse ?? c.whenTrue ?? state
            if c.whenTrue == nil { muted += 1 }
            let yesValue = eval(yes, &yesState)
            if c.whenTrue == nil { muted -= 1 }
            if c.whenFalse == nil { muted += 1 }
            let noValue = eval(no, &noState)
            if c.whenFalse == nil { muted -= 1 }
            state = clearingResources(forget(state, summary(of: node).assigned), keys: summary(of: node).used)
            return yesValue.joined(with: noValue)
        case "cast_expression":
            guard let value = node.child(byFieldName: "value") else { return JavaFlowValue() }
            var result = eval(value, &state)
            result.constant = nil
            return result
        case "instanceof_expression":
            _ = cond(node, state)
            return JavaFlowValue(nullness: .nonNull)
        case "lambda_expression", "method_reference", "switch_expression":
            let effects = summary(of: node)
            state = clearingResources(forget(state, effects.assigned), keys: effects.used)
            return node.type == "switch_expression" ? JavaFlowValue() : JavaFlowValue(nullness: .nonNull)
        case "class_body":
            state = clearingResources(state, keys: summary(of: node).used)
            return JavaFlowValue()
        default:
            for child in node.namedChildren where !Self.comments.contains(child.type) { _ = eval(child, &state) }
            return JavaFlowValue()
        }
    }

    private func evalAssignment(_ node: SyntaxNode, _ state: inout JavaFlowState) -> JavaFlowValue {
        guard let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right") else { return JavaFlowValue() }
        let op = node.operatorText ?? "="
        let target = left.unparenthesized
        if target.type == "identifier", let key = key(of: target) {
            var value = eval(right, &state)
            if op != "=" {
                markRead(key, &state)
                state.values.removeValue(forKey: key)
                return JavaFlowValue()
            }
            recordStore(key: key, name: target.text, value: right, isInitializer: false, &state)
            value.resource = JavaResourceState.none
            if isCloseableCreation(right) {
                value.resource = .open
                resourceNodes[key] = resourceNodes[key] ?? target
            }
            state.values[key] = value
            value.resource = JavaResourceState.none
            return value
        }
        switch target.type {
        case "field_access":
            if let object = target.child(byFieldName: "object") { receiver(object, &state) }
        case "array_access":
            if let array = target.child(byFieldName: "array") { receiver(array, &state) }
            if let index = target.child(byFieldName: "index") { _ = eval(index, &state) }
        default:
            break
        }
        _ = eval(right, &state)
        return JavaFlowValue()
    }

    private func evalInvocation(_ node: SyntaxNode, _ state: inout JavaFlowState) -> JavaFlowValue {
        if let object = node.child(byFieldName: "object") {
            let target = object.unparenthesized
            let arguments = node.child(byFieldName: "arguments")
            if target.type == "identifier", let key = key(of: target) {
                receiver(target, &state)
                if node.child(byFieldName: "name")?.text == "close", arguments?.namedChildCount == 0,
                   let resource = state.values[key]?.resource, resource == .open || resource == .mixed {
                    state.values[key]?.resource = .closed
                }
            } else {
                receiver(target, &state)
            }
        }
        if let arguments = node.child(byFieldName: "arguments") {
            for argument in arguments.namedChildren { _ = eval(argument, &state) }
        }
        return JavaFlowValue()
    }

    private func evalBinary(_ node: SyntaxNode, _ state: inout JavaFlowState) -> JavaFlowValue {
        guard let op = node.operatorText, let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right") else { return JavaFlowValue() }
        if op == "&&" || op == "||" || op == "==" || op == "!=" || op == "<" || op == ">" || op == "<=" || op == ">=" {
            // As a value, the test narrows nothing afterwards; only assignments inside it matter.
            let c = cond(node, state)
            state = forget(state, summary(of: node).assigned)
            if c.whenFalse == nil, c.whenTrue != nil { return JavaFlowValue(nullness: .nonNull, constant: .bool(true)) }
            if c.whenTrue == nil, c.whenFalse != nil { return JavaFlowValue(nullness: .nonNull, constant: .bool(false)) }
            return JavaFlowValue(nullness: .nonNull)
        }
        let a = eval(left, &state)
        let b = eval(right, &state)
        guard case .int(let x)? = a.constant, case .int(let y)? = b.constant else {
            return JavaFlowValue(nullness: op == "+" ? .unknown : .nonNull)
        }
        let result: Int?
        switch op {
        case "+": result = x + y
        case "-": result = x - y
        case "*": result = x.multipliedReportingOverflow(by: y).overflow ? nil : x * y
        default: result = nil
        }
        guard let result, abs(result) <= Int(Int32.max) else { return JavaFlowValue(nullness: .nonNull) }
        return JavaFlowValue(nullness: .nonNull, constant: .int(result))
    }
}
