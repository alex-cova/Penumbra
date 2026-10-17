import EditorIntelligence
import Foundation

/// Quick fixes for Java: "Import 'a.b.X'" for the type at the caret, "Import static 'Owner.member'"
/// for an unqualified call or field, "Replace with single class imports" on a star import, and an
/// organize-imports action that removes the imports nothing uses and sorts the rest.
public actor JavaCodeActionProvider: CodeActionProviding {
    private let index: JavaIndex
    private var classpathModel: JavaGradleProjectModel?
    private var classpathPaths: JavaIndexPaths?
    private var suppressionStyle: JavaSuppressionStyle = .annotation
    private var quietFindingsSource: (@Sendable (URL) async -> [Diagnostic])?

    /// Most import candidates offered for one unresolved name.
    private static let maxImportCandidates = 8
    private var importPolicy = JavaImportPolicy.intellij

    /// The auto-import and star-import settings. The default matches IntelliJ's Java code style.
    public func setImportPolicy(_ policy: JavaImportPolicy) {
        importPolicy = policy
    }

    public init(index: JavaIndex) {
        self.index = index
    }

    /// Installs or clears the source-set classpath used to scope import candidates. `nil` sees
    /// every shard.
    public func setSourceSetClasspath(_ model: JavaGradleProjectModel?, indexPaths: JavaIndexPaths) {
        classpathModel = model
        classpathPaths = model == nil ? nil : indexPaths
    }

    /// Whether Suppress fixes add `@SuppressWarnings` or a `//noinspection` comment.
    public func setSuppressionStyle(_ style: JavaSuppressionStyle) {
        suppressionStyle = style
    }

    /// Where findings set to "No highlighting (fix available)" come from (the inspection service),
    /// so their fixes are still offered although nothing is drawn.
    public func setQuietFindingsSource(_ source: (@Sendable (URL) async -> [Diagnostic])?) {
        quietFindingsSource = source
    }

    public func codeActions(
        for document: Document,
        at position: TextPosition,
        diagnostics: [Diagnostic]
    ) async -> [CodeAction] {
        guard document.languageIdentifier == "java" else { return [] }
        let text = JavaNavigationText.fullText(of: document)
        guard !text.isEmpty else { return [] }
        let scope = scope(for: document.url)
        var diagnostics = diagnostics
        if let source = quietFindingsSource, let url = document.url {
            diagnostics.append(contentsOf: await source(url))
        }
        return await JavaIndex.$queryScope.withValue(scope) { [diagnostics] in
            var actions = await importActions(in: text, at: position, diagnostics: diagnostics)
            actions.append(contentsOf: await JavaCompilerQuickFixes.actions(
                in: text, at: position, diagnostics: diagnostics, index: index))
            actions.append(contentsOf: inspectionFixes(in: text, at: position, diagnostics: diagnostics))
            actions.append(contentsOf: suppressionActions(in: text, at: position, diagnostics: diagnostics))
            let organized = JavaImportOrganizer.edits(in: text, policy: importPolicy)
            if !organized.isEmpty {
                let unused = JavaUnusedImports.edits(in: text).count
                actions.append(CodeAction(
                    title: unused == 0 ? "Sort imports" : "Optimize imports (remove \(unused) unused)",
                    kind: CodeAction.organizeImportsKind,
                    edits: organized
                ))
            }
            return actions
        }
    }

    /// Fixes for the `java-inspection` findings on the caret's line (the rule's own quick fixes,
    /// then "Fix all" when the rule has more findings in the file and the commands to disable it or
    /// turn its highlighting off), each rule's group once.
    private func inspectionFixes(in text: String, at position: TextPosition, diagnostics: [Diagnostic]) -> [CodeAction] {
        let ns = text as NSString
        let caret = min(max(0, position.utf16Offset), ns.length)
        let caretLine = ns.lineRange(for: NSRange(location: caret, length: 0))
        let inspections = diagnostics.filter { $0.source == "java-inspection" && $0.code != nil }
        let candidates = inspections.filter { diagnostic in
            let range = ProblemLocator.nsRange(for: diagnostic.range, in: text)
            return NSIntersectionRange(ns.lineRange(for: NSRange(location: range.location, length: 0)), caretLine).length > 0
        }
        guard !candidates.isEmpty, let tree = JavaSyntaxParser().parse(text) else { return [] }
        var actions: [CodeAction] = []
        var seenCodes = Set<String>()
        for diagnostic in candidates {
            let fixes = JavaInspectionFixes.fixes(for: diagnostic, tree: tree, source: text)
            actions.append(contentsOf: fixes)
            guard let code = diagnostic.code, let rule = JavaInspectionRule(code: code), seenCodes.insert(code).inserted else { continue }
            let sameRule = inspections.filter { $0.code == code }
            if rule.hasQuickFix, sameRule.count > 1 {
                let edits = JavaBatchFixer.allEdits(for: sameRule, tree: tree, source: text)
                if edits.count > 1 {
                    actions.append(CodeAction(
                        title: "Fix all '\(rule.title)' problems in file", kind: "quickfix.fixAll", edits: edits
                    ))
                }
            }
            actions.append(CodeAction(
                title: "Turn off highlighting for '\(rule.title)' (keep fix)", kind: "inspection",
                edits: [], command: CodeActionCommand(id: JavaInspectionCommand.quiet, arguments: [code])
            ))
            actions.append(CodeAction(
                title: "Disable inspection '\(rule.title)'", kind: "inspection",
                edits: [], command: CodeActionCommand(id: JavaInspectionCommand.disable, arguments: [code])
            ))
            actions.append(CodeAction(
                title: "Edit inspection settings…", kind: "inspection",
                edits: [], command: CodeActionCommand(id: JavaInspectionCommand.configure, arguments: [code])
            ))
        }
        return actions
    }

    /// "Suppress for method / class…" (or a `//noinspection` comment) for each warning on the
    /// caret's line that has a code to suppress.
    private func suppressionActions(in text: String, at position: TextPosition, diagnostics: [Diagnostic]) -> [CodeAction] {
        let ns = text as NSString
        let caret = min(max(0, position.utf16Offset), ns.length)
        let caretLine = ns.lineRange(for: NSRange(location: caret, length: 0))
        let candidates = diagnostics.filter { diagnostic in
            guard diagnostic.severity != .error, diagnostic.code != nil,
                  diagnostic.source == "java-inspection" || diagnostic.source == "javac" else { return false }
            let range = ProblemLocator.nsRange(for: diagnostic.range, in: text)
            return NSIntersectionRange(ns.lineRange(for: NSRange(location: range.location, length: 0)), caretLine).length > 0
        }
        guard !candidates.isEmpty, let tree = JavaSyntaxParser().parse(text) else { return [] }
        var actions: [CodeAction] = []
        var seen = Set<String>()
        for diagnostic in candidates {
            guard let code = diagnostic.code, seen.insert(code).inserted else { continue }
            let range = ProblemLocator.nsRange(for: diagnostic.range, in: text)
            let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.location, in: text)
            actions.append(contentsOf: JavaSuppression.fixes(
                code: code, atByteOffset: byteOffset, tree: tree, source: text, style: suppressionStyle
            ))
        }
        return actions
    }

    // MARK: - Import fixes

    private func importActions(in text: String, at position: TextPosition, diagnostics: [Diagnostic]) async -> [CodeAction] {
        guard let tree = JavaSyntaxParser().parse(text) else { return [] }
        let fileStubs = JavaSourceStubBuilder.build(tree: tree, url: URL(fileURLWithPath: "/unsaved/CodeActions.java"))
        let inserter = JavaImportInserter(
            text: text, bytes: tree.sourceBytes, tree: tree, fileStubs: fileStubs, policy: importPolicy
        )
        var actions: [CodeAction] = []
        var offeredClassNames = Set<String>()
        if let (node, _) = JavaRefactoringText.identifierToken(atUTF16Offset: position.utf16Offset, in: text),
           !isInsideImportOrPackage(node) {
            actions += await classImportActions(
                for: node.text, inserter: inserter, packageName: fileStubs.packageName, offered: &offeredClassNames
            )
            if isUnqualifiedMember(node) {
                actions += await staticImportActions(
                    for: node.text, inserter: inserter, packageName: fileStubs.packageName
                )
            }
        }
        for name in unresolvedClassNames(in: text, at: position, diagnostics: diagnostics) {
            actions += await classImportActions(
                for: name, inserter: inserter, packageName: fileStubs.packageName, offered: &offeredClassNames
            )
        }
        let expanded = await JavaAutoImport.expandStarEdits(
            in: text, caretUTF16: position.utf16Offset, index: index, policy: importPolicy
        )
        if !expanded.isEmpty {
            actions.append(CodeAction(title: "Replace with single class imports", kind: "quickfix", edits: expanded))
        }
        return actions.enumerated().map { index, action in
            CodeAction(title: action.title, kind: action.kind, edits: action.edits, isPreferred: index == 0 && action.kind == "quickfix")
        }
    }

    private func classImportActions(
        for name: String, inserter: JavaImportInserter, packageName: String, offered: inout Set<String>
    ) async -> [CodeAction] {
        guard offered.insert(name).inserted else { return [] }
        let candidates = await index.classes(simpleName: name, limit: 200)
            .filter { JavaImportPolicy.isImportable($0, from: packageName) && !importPolicy.excludesClass($0) }
            .sorted { ($0.outerQualifiedName == nil ? 0 : 1, $0.qualifiedName) < ($1.outerQualifiedName == nil ? 0 : 1, $1.qualifiedName) }
            .prefix(Self.maxImportCandidates)
        var actions: [CodeAction] = []
        for stub in candidates {
            guard case .addImport(let edit) = inserter.decision(for: stub) else { continue }
            actions.append(CodeAction(title: "Import '\(stub.qualifiedName)'", kind: "quickfix", edits: [edit]))
        }
        return actions
    }

    private func staticImportActions(
        for name: String, inserter: JavaImportInserter, packageName: String
    ) async -> [CodeAction] {
        var seen = Set<String>()
        var actions: [CodeAction] = []
        func offer(owner: String) {
            let qualified = "\(owner).\(name)"
            guard seen.insert(qualified).inserted, actions.count < Self.maxImportCandidates else { return }
            guard !importPolicy.excludesStaticMember(owner: owner, name: name) else { return }
            guard case .addImport(let edit) = inserter.decisionForStaticMember(owner: owner, member: name) else { return }
            actions.append(CodeAction(title: "Import static '\(qualified)'", kind: "quickfix", edits: [edit]))
        }
        for match in await index.members(matching: name, limit: 40) where match.name == name && match.isStatic {
            guard let stub = await index.classStub(qualifiedName: match.ownerQualifiedName),
                  staticMemberIsAccessible(name, on: stub, from: packageName) else { continue }
            offer(owner: match.ownerQualifiedName)
        }
        for owner in importPolicy.staticMemberOwners where actions.count < Self.maxImportCandidates {
            guard let stub = await index.classStub(qualifiedName: owner),
                  staticMemberIsAccessible(name, on: stub, from: packageName) else { continue }
            offer(owner: owner)
        }
        return actions
    }

    private func staticMemberIsAccessible(_ name: String, on stub: JavaClassStub, from packageName: String) -> Bool {
        let modifiers = stub.methods.first { !$0.isConstructor && $0.name == name && $0.modifiers.contains(.staticFlag) }?.modifiers
            ?? stub.fields.first { $0.name == name && $0.modifiers.contains(.staticFlag) }?.modifiers
        guard let modifiers else { return false }
        if modifiers.contains(.publicFlag) { return true }
        if modifiers.contains(.privateFlag) { return false }
        return stub.packageName == packageName
    }

    private func isUnqualifiedMember(_ node: SyntaxNode) -> Bool {
        guard let parent = node.parent else { return false }
        switch parent.type {
        case "method_invocation":
            return parent.child(byFieldName: "object") == nil && parent.child(byFieldName: "name")?.startByte == node.startByte
        case "field_access":
            return parent.child(byFieldName: "object") == nil && parent.child(byFieldName: "field")?.startByte == node.startByte
        default:
            return false
        }
    }

    private func isInsideImportOrPackage(_ node: SyntaxNode) -> Bool {
        var current: SyntaxNode? = node
        while let node = current {
            if node.type == "import_declaration" || node.type == "package_declaration" { return true }
            current = node.parent
        }
        return false
    }

    /// The `X` of every `cannot find symbol … symbol: class X` diagnostic on the caret's line.
    /// Keyed on `Diagnostic.code` (`javac:compiler.err.cant.resolve*`) as well as the message,
    /// so the same fix serves the native checks later: for a keyed diagnostic without the
    /// classic wording, the identifier under the diagnostic's range names the class.
    private func unresolvedClassNames(in text: String, at position: TextPosition, diagnostics: [Diagnostic]) -> [String] {
        let ns = text as NSString
        let caret = min(max(0, position.utf16Offset), ns.length)
        let caretLine = ns.lineRange(for: NSRange(location: caret, length: 0))
        var names: [String] = []
        for diagnostic in diagnostics where diagnostic.source == "javac" {
            let isCantResolve = diagnostic.message.hasPrefix("cannot find symbol")
                || (diagnostic.code?.hasPrefix("javac:compiler.err.cant.resolve") == true)
            guard isCantResolve else { continue }
            let range = ProblemLocator.nsRange(for: diagnostic.range, in: text)
            guard NSIntersectionRange(ns.lineRange(for: NSRange(location: range.location, length: 0)), caretLine).length > 0
                    || NSLocationInRange(caret, NSRange(location: range.location, length: range.length + 1)) else { continue }
            guard let name = Self.symbolClassName(in: diagnostic.message) ?? Self.identifierAt(range, in: text),
                  !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    /// The identifier the range covers, or `nil` when it is not exactly one identifier.
    private static func identifierAt(_ range: NSRange, in text: String) -> String? {
        let ns = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return nil }
        let slice = ns.substring(with: range)
        guard !slice.isEmpty, slice.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }),
              let first = slice.first, first.isLetter || first == "_" || first == "$" else { return nil }
        return slice
    }

    static func symbolClassName(in message: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"symbol:\s+class\s+([A-Za-z_$][\w$]*)"#),
              let match = regex.firstMatch(in: message, range: NSRange(location: 0, length: (message as NSString).length)) else {
            return nil
        }
        return (message as NSString).substring(with: match.range(at: 1))
    }

    private func scope(for file: URL?) -> Set<String>? {
        guard let file, let classpathModel, let classpathPaths else { return nil }
        return classpathModel.visibleShardPaths(forFile: file, paths: classpathPaths)
    }
}
