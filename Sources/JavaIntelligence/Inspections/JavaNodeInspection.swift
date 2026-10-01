import EditorIntelligence
import Foundation

/// A syntactic inspection that looks at individual tree nodes. `JavaInspectionRunner` visits the
/// tree once and hands each node to the enabled inspections that registered for its type, so the
/// cost of a pass does not grow with the number of rules.
protocol JavaNodeInspection {
    static var rule: JavaInspectionRule { get }
    /// Grammar node types this inspection wants to see (`binary_expression`, `if_statement`, …).
    static var nodeTypes: Set<String> { get }
    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void)
    /// Quick fixes for one of this rule's diagnostics. `Diagnostic` carries no edits, so they are
    /// rebuilt from the diagnostic's range against a fresh tree of the same text.
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction]
}

extension JavaNodeInspection {
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] { [] }
}

/// An inspection that needs types resolved through the index. It receives every candidate node of
/// its `nodeTypes` at once, so it can skip repeats (one resolution per receiver type and method,
/// not per call) and stop at a budget. Skipped for very large files (`JavaInspectionRunner.maxTypedLineCount`).
protocol JavaTypedInspection {
    static var rule: JavaInspectionRule { get }
    static var nodeTypes: Set<String> { get }
    static func check(nodes: [SyntaxNode], context: JavaInspectionContext, report: (JavaInspection) -> Void) async
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction]
}

extension JavaTypedInspection {
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] { [] }
}

/// Every node inspection, in the order their findings are reported.
enum JavaInspectionRegistry {
    static let nodeInspections: [any JavaNodeInspection.Type] = [
        // Probable bugs
        JavaStringComparisonInspection.self,
        JavaNumberComparisonInspection.self,
        JavaArrayComparisonInspection.self,
        JavaEmptyStatementBodyInspection.self,
        JavaSelfAssignmentInspection.self,
        JavaSelfComparisonInspection.self,
        JavaMathRandomCastInspection.self,
        JavaThrowableNotThrownInspection.self,
        JavaObjectAllocationIgnoredInspection.self,
        JavaStringBuilderCharArgumentInspection.self,
        JavaArrayObjectMethodInspection.self,
        JavaEqualsHashCodePairInspection.self,
        JavaCovariantEqualsInspection.self,
        JavaEqualInsteadOfEqualsInspection.self,
        JavaSubtractionInCompareToInspection.self,
        JavaSuspiciousIndentationInspection.self,
        JavaTextLabelInSwitchInspection.self,
        JavaAssertSideEffectsInspection.self,
        JavaConstantAssertInspection.self,
        JavaNonShortCircuitInspection.self,
        JavaComparableWithoutEqualsInspection.self,
        JavaIteratorHasNextInspection.self,
        JavaMismatchedStringCaseInspection.self,
        JavaMissingWhitespaceInspection.self,
        JavaClassNewInstanceInspection.self,
        JavaRoundingOfIntegersInspection.self,
        JavaIntegerDivisionInspection.self,
        JavaConcatenationInFormatInspection.self,
        JavaCollectionAddedToItselfInspection.self,
        JavaResultOfCallIgnoredInspection.self,
        JavaOverwrittenElementInspection.self,
        JavaInfiniteRecursionInspection.self,
        JavaDuplicatedDelimitersInspection.self,
        // Verbose or redundant code constructs
        JavaUnnecessaryReturnInspection.self,
        JavaUnnecessaryContinueInspection.self,
        JavaUnnecessaryBreakInspection.self,
        JavaUnnecessaryLabelOnBreakInspection.self,
        JavaUnnecessaryLabelOnContinueInspection.self,
        JavaConcatenationWithEmptyStringInspection.self,
        JavaManualMinMaxInspection.self,
        JavaUnnecessarilyEscapedCharacterInspection.self,
        JavaReplacementHasNoEffectInspection.self,
        JavaUnnecessaryEnumDefaultInspection.self,
        JavaRedundantFileCreationInspection.self,
        // Error handling
        JavaEmptyCatchBlockInspection.self,
        JavaCatchOfThrowableInspection.self,
        JavaCaughtExceptionRethrownInspection.self,
        JavaJumpOutOfFinallyInspection.self,
        JavaEmptyFinallyBlockInspection.self,
        JavaEmptyTryBlockInspection.self,
        // Types read from declarations
        JavaRedundantTypeCastInspection.self,
        JavaDeprecatedBoxedConstructorInspection.self,
        JavaEqualsEmptyStringInspection.self,
        JavaExplicitTypeArgumentsInspection.self,
        JavaStringConcatenationInLoopInspection.self,
        // Naming conventions
        JavaClassNamingInspection.self,
        JavaMethodNamingInspection.self,
        JavaFieldNamingInspection.self,
        JavaLocalVariableNamingInspection.self,
        JavaParameterNamingInspection.self,
        JavaTypeParameterNamingInspection.self,
        JavaEnumConstantNamingInspection.self,
        JavaNonConstantFieldNamedLikeConstantInspection.self,
        JavaMethodNameSameAsClassInspection.self,
        // Control flow
        JavaRedundantIfStatementInspection.self,
        JavaSimplifiableConditionalInspection.self,
        JavaIdenticalBranchesInspection.self,
        JavaDuplicateSwitchBranchesInspection.self,
        JavaPointlessBooleanInspection.self,
        JavaConstantConditionInspection.self,
        JavaInfiniteLoopInspection.self,
        JavaLoopDoesNotLoopInspection.self,
        // Code maturity
        JavaPrintStackTraceInspection.self,
        JavaSystemOutErrInspection.self,
        JavaSystemGcInspection.self,
        JavaObsoleteCollectionInspection.self,
        JavaFinalizeDeclaredInspection.self,
        // Declaration redundancy
        JavaUnusedLabelInspection.self,
        JavaDuplicateThrowsInspection.self,
        JavaEmptyClassInitializerInspection.self,
        JavaRedundantCloseInspection.self,
    ]

    static let typedInspections: [any JavaTypedInspection.Type] = [
        JavaAccessStaticViaInstanceInspection.self,
        JavaRedundantArrayCreationInspection.self,
        JavaSizeComparisonWithZeroInspection.self,
        JavaDeprecatedApiInspection.self,
    ]

    static func inspection(for rule: JavaInspectionRule) -> (any JavaNodeInspection.Type)? {
        nodeInspections.first { $0.rule == rule }
    }

    static func typedInspection(for rule: JavaInspectionRule) -> (any JavaTypedInspection.Type)? {
        typedInspections.first { $0.rule == rule }
    }

    /// Whether a registered inspection (node or typed) can produce fixes for `rule`.
    static func isRegistered(_ rule: JavaInspectionRule) -> Bool {
        inspection(for: rule) != nil || typedInspection(for: rule) != nil
    }

    /// Quick fixes for a `java-inspection` diagnostic whose rule is a registered node inspection.
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let code = diagnostic.code, let rule = JavaInspectionRule(code: code) else { return [] }
        if let inspection = inspection(for: rule) { return inspection.fixes(for: diagnostic, tree: tree, source: source) }
        return typedInspection(for: rule)?.fixes(for: diagnostic, tree: tree, source: source) ?? []
    }
}

enum JavaInspectionRunner {
    /// One DFS over the named nodes; each node goes to the enabled inspections registered for its type.
    static func run(
        context: JavaInspectionContext,
        enabled: Set<JavaInspectionRule>,
        inspections: [any JavaNodeInspection.Type] = JavaInspectionRegistry.nodeInspections
    ) -> [JavaInspection] {
        var table: [String: [any JavaNodeInspection.Type]] = [:]
        for inspection in inspections where enabled.contains(inspection.rule) {
            for type in inspection.nodeTypes { table[type, default: []].append(inspection) }
        }
        guard !table.isEmpty else { return [] }
        var found: [JavaInspection] = []
        var stack = [context.tree.rootNode]
        while let node = stack.popLast() {
            if let interested = table[node.type] {
                for inspection in interested {
                    inspection.check(node: node, context: context) { found.append($0) }
                }
            }
            for index in (0..<node.namedChildCount).reversed() {
                if let child = node.namedChild(at: index) { stack.append(child) }
            }
        }
        return found
    }
}

extension JavaInspectionRunner {
    /// Typed inspections look every call up in the index, so a file this long skips them.
    static let maxTypedLineCount = 20_000

    static func runTyped(
        context: JavaInspectionContext,
        enabled: Set<JavaInspectionRule>,
        inspections: [any JavaTypedInspection.Type] = JavaInspectionRegistry.typedInspections
    ) async -> [JavaInspection] {
        let active = inspections.filter { enabled.contains($0.rule) }
        guard !active.isEmpty else { return [] }
        let lineCount = context.tree.sourceBytes.reduce(0) { $0 + ($1 == JavaSourceBytes.newline ? 1 : 0) }
        guard lineCount <= maxTypedLineCount else { return [] }
        var wanted = Set<String>()
        for inspection in active { wanted.formUnion(inspection.nodeTypes) }
        var nodesByType: [String: [SyntaxNode]] = [:]
        var stack = [context.tree.rootNode]
        while let node = stack.popLast() {
            if wanted.contains(node.type) { nodesByType[node.type, default: []].append(node) }
            for index in (0..<node.namedChildCount).reversed() {
                if let child = node.namedChild(at: index) { stack.append(child) }
            }
        }
        var found: [JavaInspection] = []
        for inspection in active {
            var nodes: [SyntaxNode] = []
            for type in inspection.nodeTypes { nodes.append(contentsOf: nodesByType[type] ?? []) }
            nodes.sort { $0.startByte < $1.startByte }
            guard !nodes.isEmpty else { continue }
            await inspection.check(nodes: nodes, context: context) { found.append($0) }
        }
        return found
    }
}

/// Helpers shared by node inspections and their fixes.
enum JavaInspectionSupport {
    /// A navigation session positioned at `byteOffset`, for resolving types and overloads there.
    static func session(for context: JavaInspectionContext, at byteOffset: Int) -> JavaNavigationSession {
        JavaNavigationSession(
            source: context.source, fileURL: context.url, tree: context.tree, byteOffset: byteOffset,
            fileStubs: context.file, index: context.index, jdkHome: nil,
            cacheRoot: FileManager.default.temporaryDirectory, openBuffer: nil,
            decompile: JavaDecompileGate(policy: .denied)
        )
    }

    static func position(forByte byteOffset: Int, in tree: JavaSyntaxTree) -> TextPosition {
        tree.declarationCache.positionIndex(for: tree.sourceBytes).position(forByteOffset: byteOffset)
    }

    static func inspection(
        _ rule: JavaInspectionRule,
        message: String,
        startByte: Int,
        endByte: Int,
        tree: JavaSyntaxTree,
        fixTitle: String? = nil
    ) -> JavaInspection {
        JavaInspection(
            id: rule.code,
            message: message,
            severity: rule.defaultSeverity,
            range: EditorIntelligence.TextRange(
                start: position(forByte: startByte, in: tree),
                end: position(forByte: endByte, in: tree)
            ),
            fixTitle: fixTitle
        )
    }

    static func inspection(
        _ rule: JavaInspectionRule,
        message: String,
        node: SyntaxNode,
        fixTitle: String? = nil
    ) -> JavaInspection {
        inspection(rule, message: message, startByte: node.startByte, endByte: node.endByte, tree: node.tree, fixTitle: fixTitle)
    }

    /// The node of `type` whose range is exactly the diagnostic's range. Rules that report a
    /// sub-node (a method name, say) ask for that node's type and step to its parent.
    static func node(of type: String, for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> SyntaxNode? {
        let range = ProblemLocator.nsRange(for: diagnostic.range, in: source)
        let start = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.location, in: source)
        let end = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.location + range.length, in: source)
        var current: SyntaxNode? = tree.node(atByteOffset: start)
        while let node = current {
            if node.type == type, node.startByte == start, node.endByte == end { return node }
            current = node.parent
        }
        return nil
    }

    static func edit(replacingBytes range: Range<Int>, with replacement: String, in tree: JavaSyntaxTree) -> TextEdit {
        TextEdit(
            range: EditorIntelligence.TextRange(
                start: position(forByte: range.lowerBound, in: tree),
                end: position(forByte: range.upperBound, in: tree)
            ),
            replacement: replacement
        )
    }
}
