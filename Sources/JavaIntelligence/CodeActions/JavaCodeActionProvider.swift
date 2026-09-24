import EditorIntelligence
import Foundation

/// Quick fixes for Java: "Import `a.b.X`" for a `cannot find symbol … class X` error under the
/// caret, and an organize-imports action that removes the imports nothing uses and sorts the rest.
public actor JavaCodeActionProvider: CodeActionProviding {
    private let index: JavaIndex
    private var classpathModel: JavaGradleProjectModel?
    private var classpathPaths: JavaIndexPaths?

    /// Most import candidates offered for one unresolved name.
    private static let maxImportCandidates = 8

    public init(index: JavaIndex) {
        self.index = index
    }

    /// Installs or clears the source-set classpath used to scope import candidates. `nil` sees
    /// every shard.
    public func setSourceSetClasspath(_ model: JavaGradleProjectModel?, indexPaths: JavaIndexPaths) {
        classpathModel = model
        classpathPaths = model == nil ? nil : indexPaths
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
        return await JavaIndex.$queryScope.withValue(scope) {
            var actions = await importActions(in: text, at: position, diagnostics: diagnostics)
            actions.append(contentsOf: overrideActions(in: text, at: position, diagnostics: diagnostics))
            actions.append(contentsOf: inspectionImportFixes(in: text, at: position, diagnostics: diagnostics))
            let organized = JavaImportOrganizer.edits(in: text)
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

    private func overrideActions(in text: String, at position: TextPosition, diagnostics: [Diagnostic]) -> [CodeAction] {
        guard let tree = JavaSyntaxParser().parse(text) else { return [] }
        let ns = text as NSString
        let caret = min(max(0, position.utf16Offset), ns.length)
        let caretLine = ns.lineRange(for: NSRange(location: caret, length: 0))
        var actions: [CodeAction] = []
        for diagnostic in diagnostics where diagnostic.source == "java-inspection" && diagnostic.code == "missing-override" {
            let range = ProblemLocator.nsRange(for: diagnostic.range, in: text)
            guard NSIntersectionRange(ns.lineRange(for: NSRange(location: range.location, length: 0)), caretLine).length > 0 else { continue }
            let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.location, in: text)
            guard let methodNode = enclosingMethodNode(at: byteOffset, in: tree) else { continue }
            let insertByte = methodNode.startByte
            let indent = leadingIndent(of: methodNode, in: tree)
            let replacement = "@Override\n\(indent)"
            let edit = TextEdit(
                range: TextRange(
                    start: JavaImportInserter.textPosition(forByteOffset: insertByte, in: tree.sourceBytes),
                    end: JavaImportInserter.textPosition(forByteOffset: insertByte, in: tree.sourceBytes)
                ),
                replacement: replacement
            )
            actions.append(CodeAction(title: "Add @Override", kind: "quickfix", edits: [edit], isPreferred: true))
        }
        return actions
    }

    private func inspectionImportFixes(in text: String, at position: TextPosition, diagnostics: [Diagnostic]) -> [CodeAction] {
        let ns = text as NSString
        let caret = min(max(0, position.utf16Offset), ns.length)
        let caretLine = ns.lineRange(for: NSRange(location: caret, length: 0))
        var actions: [CodeAction] = []
        for diagnostic in diagnostics where diagnostic.source == "java-inspection" {
            let range = ProblemLocator.nsRange(for: diagnostic.range, in: text)
            guard NSIntersectionRange(ns.lineRange(for: NSRange(location: range.location, length: 0)), caretLine).length > 0 else {
                continue
            }
            switch diagnostic.code {
            case "unused-import", "duplicate-import", "unresolved-import":
                guard let title = diagnostic.message.contains("import") ? removeImportTitle(for: diagnostic.code ?? "") : nil else { continue }
                let edit = TextEdit(range: diagnostic.range, replacement: "")
                actions.append(CodeAction(title: title, kind: "quickfix", edits: [edit], isPreferred: true))
            default:
                continue
            }
        }
        return actions
    }

    private func removeImportTitle(for code: String) -> String? {
        switch code {
        case "unused-import": return "Remove unused import"
        case "duplicate-import": return "Remove duplicate import"
        case "unresolved-import": return "Remove import"
        default: return nil
        }
    }

    private func enclosingMethodNode(at byteOffset: Int, in tree: JavaSyntaxTree) -> SyntaxNode? {
        var current: SyntaxNode? = tree.node(atByteOffset: byteOffset)
        while let walk = current {
            if walk.type == "method_declaration" { return walk }
            current = walk.parent
        }
        return nil
    }

    private func leadingIndent(of methodNode: SyntaxNode, in tree: JavaSyntaxTree) -> String {
        let lineStart = tree.sourceBytes[..<methodNode.startByte].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? 0
        let prefix = tree.sourceBytes[lineStart..<methodNode.startByte]
        return String(decoding: prefix.prefix { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }, as: UTF8.self)
    }

    // MARK: - Import fixes

    private func importActions(in text: String, at position: TextPosition, diagnostics: [Diagnostic]) async -> [CodeAction] {
        let names = unresolvedClassNames(in: text, at: position, diagnostics: diagnostics)
        guard !names.isEmpty, let tree = JavaSyntaxParser().parse(text) else { return [] }
        let fileStubs = JavaSourceStubBuilder.build(tree: tree, url: URL(fileURLWithPath: "/unsaved/CodeActions.java"))
        let inserter = JavaImportInserter(text: text, bytes: tree.sourceBytes, tree: tree, fileStubs: fileStubs)
        var actions: [CodeAction] = []
        for name in names {
            let candidates = await index.classes(simpleNamePrefix: name, limit: 200)
                .filter { $0.simpleName == name && isImportable($0, from: fileStubs.packageName) }
                .sorted { ($0.outerQualifiedName == nil ? 0 : 1, $0.qualifiedName) < ($1.outerQualifiedName == nil ? 0 : 1, $1.qualifiedName) }
                .prefix(Self.maxImportCandidates)
            for stub in candidates {
                guard case .addImport(let edit) = inserter.decision(for: stub) else { continue }
                actions.append(CodeAction(
                    title: "Import '\(stub.qualifiedName)'",
                    kind: "quickfix",
                    edits: [edit],
                    isPreferred: actions.isEmpty
                ))
            }
        }
        return actions
    }

    /// The `X` of every `cannot find symbol … symbol: class X` diagnostic on the caret's line.
    private func unresolvedClassNames(in text: String, at position: TextPosition, diagnostics: [Diagnostic]) -> [String] {
        let ns = text as NSString
        let caret = min(max(0, position.utf16Offset), ns.length)
        let caretLine = ns.lineRange(for: NSRange(location: caret, length: 0))
        var names: [String] = []
        for diagnostic in diagnostics where diagnostic.source == "javac" && diagnostic.message.hasPrefix("cannot find symbol") {
            let range = ProblemLocator.nsRange(for: diagnostic.range, in: text)
            guard NSIntersectionRange(ns.lineRange(for: NSRange(location: range.location, length: 0)), caretLine).length > 0
                    || NSLocationInRange(caret, NSRange(location: range.location, length: range.length + 1)) else { continue }
            guard let name = Self.symbolClassName(in: diagnostic.message), !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    static func symbolClassName(in message: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"symbol:\s+class\s+([A-Za-z_$][\w$]*)"#),
              let match = regex.firstMatch(in: message, range: NSRange(location: 0, length: (message as NSString).length)) else {
            return nil
        }
        return (message as NSString).substring(with: match.range(at: 1))
    }

    /// A class from another package must be public to be importable.
    private func isImportable(_ stub: JavaClassStub, from package: String) -> Bool {
        stub.packageName == package || stub.modifiers.contains(.publicFlag)
    }

    private func scope(for file: URL?) -> Set<String>? {
        guard let file, let classpathModel, let classpathPaths else { return nil }
        return classpathModel.visibleShardPaths(forFile: file, paths: classpathPaths)
    }
}
