import EditorIntelligence
import Foundation

/// Moves a top-level type to another package: updates the `package` declaration, qualified
/// references across the project, and renames/moves the `.java` file.
enum JavaMoveClass {
    static let title = "Move Class"

    // MARK: - Availability

    static func isAvailable(
        source: String, caretOffset: Int, url: URL, environment: JavaReferenceEnvironment, index: JavaIndex
    ) async -> Bool {
        await resolveTopLevelType(
            source: source, caretOffset: caretOffset, url: url, environment: environment, index: index
        ) != nil
    }

    // MARK: - Plan

    static func plan(
        source: String, caretOffset: Int, url: URL, targetPackage: String,
        index: JavaIndex, candidates: any JavaUsageCandidateSource, roots: [URL],
        environment: JavaReferenceEnvironment, isReadOnly: @Sendable (URL) -> Bool
    ) async -> WorkspaceEditPlan {
        if let problem = RenameTarget.validatePackageName(targetPackage) {
            return blocked(problem)
        }
        guard let resolved = await resolveTopLevelType(
            source: source, caretOffset: caretOffset, url: url, environment: environment, index: index
        ) else {
            return blocked("Place the caret on a top-level class, interface, enum, record, or annotation.")
        }

        let stub = resolved.stub
        let oldPackage = stub.packageName
        let normalizedTarget = normalizePackage(targetPackage)
        if normalizedTarget == oldPackage {
            return blocked("\(stub.simpleName) is already in \(packageDescription(normalizedTarget)).")
        }

        let oldQualified = stub.qualifiedName
        let newQualified = normalizedTarget.isEmpty ? stub.simpleName : "\(normalizedTarget).\(stub.simpleName)"
        let declaringURL = resolved.declaringURL

        if isReadOnly(declaringURL) {
            return blocked("\(stub.simpleName) is declared in generated code and cannot be moved.")
        }

        let newURL = targetFileURL(
            declaringURL: declaringURL, oldPackage: oldPackage, targetPackage: normalizedTarget, simpleName: stub.simpleName
        )
        if FileManager.default.fileExists(atPath: newURL.path) {
            return blocked("\(newURL.lastPathComponent) already exists at the destination.")
        }
        if await index.classStub(qualifiedName: newQualified) != nil {
            return blocked("A type named \(stub.simpleName) already exists in \(packageDescription(normalizedTarget)).")
        }

        var plan = WorkspaceEditPlan(title: title)
        let id = JavaSymbolID.type(qualifiedName: oldQualified)
        let searchRoots = roots.isEmpty ? [declaringURL.deletingLastPathComponent()] : roots

        if let packageEntry = packageDeclarationEntry(
            in: source, url: declaringURL, oldPackage: oldPackage, newPackage: normalizedTarget
        ) {
            plan.entries.append(packageEntry)
        } else {
            plan.warnings.append("Could not find a package declaration to update in \(declaringURL.lastPathComponent).")
        }

        var usages = await JavaUsageSearch.collect(
            id, candidates: candidates, roots: searchRoots, environment: environment, includeDeclarations: true
        )
        var seenFiles = Set(usages.map { $0.url.standardizedFileURL.path })
        var extra = [declaringURL]
        if url.standardizedFileURL != declaringURL { extra.append(url.standardizedFileURL) }
        for file in extra where seenFiles.insert(file.path).inserted {
            guard let text = await readText(of: file, environment: environment) else { continue }
            usages += await JavaFileUsageResolver.usages(of: id, source: text, url: file, environment: environment)
        }

        var seen = Set<String>()
        func append(_ entry: WorkspaceEditPlanEntry) {
            let key = "\(entry.url.path):\(entry.range.start.utf16Offset):\(entry.oldText)"
            guard seen.insert(key).inserted else { return }
            plan.entries.append(entry)
        }

        for usage in usages {
            guard usage.kind != .declaration || usage.url.standardizedFileURL == declaringURL else { continue }
            guard let text = await readText(of: usage.url, environment: environment) else { continue }
            if let entry = referenceEntry(
                usage: usage, source: text, url: usage.url,
                oldQualifiedName: oldQualified, newQualifiedName: newQualified,
                oldPackage: oldPackage, readOnly: isReadOnly(usage.url)
            ) {
                append(entry)
            } else if usage.url.standardizedFileURL != declaringURL,
                      filePackage(in: text) == oldPackage, usage.kind != .import {
                plan.warnings.append(
                    "Unqualified references to \(stub.simpleName) in \(usage.url.lastPathComponent) may need an import after the move."
                )
            }
        }

        var fileSet = Set(await candidates.candidateFiles(containing: stub.simpleName, in: searchRoots).map(\.standardizedFileURL))
        fileSet.insert(declaringURL)
        for file in fileSet.sorted(by: { $0.path < $1.path }) {
            guard let text = await readText(of: file, environment: environment), text.contains(stub.simpleName) else { continue }
            for usage in JavaRenameProvider.importUsages(qualifiedName: oldQualified, in: text, url: file) {
                if let entry = importEntry(
                    usage: usage, source: text, url: file,
                    oldQualifiedName: oldQualified, newQualifiedName: newQualified,
                    readOnly: isReadOnly(file)
                ) {
                    append(entry)
                }
            }
            for usage in moveJavadocUsages(
                stub: stub, oldQualifiedName: oldQualified, newQualifiedName: newQualified, in: text, url: file
            ) {
                if let entry = referenceEntry(
                    usage: usage, source: text, url: file,
                    oldQualifiedName: oldQualified, newQualifiedName: newQualified,
                    oldPackage: oldPackage, readOnly: isReadOnly(file)
                ) {
                    append(entry)
                }
            }
        }

        plan.entries.sort {
            $0.url.path != $1.url.path ? $0.url.path < $1.url.path : $0.range.start.utf16Offset < $1.range.start.utf16Offset
        }
        plan.fileRenames = [(from: declaringURL, to: newURL)]
        if plan.entries.contains(where: \.isReadOnly) {
            plan.warnings.append("Some usages are in generated files and will not be changed.")
        }
        return plan
    }

    // MARK: - Resolution

    private struct ResolvedType {
        let stub: JavaClassStub
        let declaringURL: URL
    }

    private static func resolveTopLevelType(
        source: String, caretOffset: Int, url: URL, environment: JavaReferenceEnvironment, index: JavaIndex
    ) async -> ResolvedType? {
        guard var id = await JavaSymbolIdentity.symbolID(
            at: caretOffset, in: source, url: url, environment: environment
        ) else { return nil }
        if case .constructor(let declaringClass, _) = id { id = .type(qualifiedName: declaringClass) }
        guard case .type(let qualifiedName) = id else { return nil }
        guard let tokenRange = identifierRange(at: caretOffset, in: source) else { return nil }
        let name = JavaRenameProvider.text(of: tokenRange, in: source)
        guard String(qualifiedName.split(separator: ".").last ?? "") == name else { return nil }
        guard let stub = await index.classStub(qualifiedName: qualifiedName), stub.outerQualifiedName == nil else { return nil }
        guard case .source(let declaringFile, _) = stub.origin else { return nil }
        return ResolvedType(stub: stub, declaringURL: declaringFile.standardizedFileURL)
    }

    // MARK: - Package and paths

    private static func normalizePackage(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func packageDescription(_ package: String) -> String {
        package.isEmpty ? "the default package" : "package \(package)"
    }

    private static func sourceRoot(of declaringURL: URL, packageName: String) -> URL {
        if packageName.isEmpty { return declaringURL.deletingLastPathComponent() }
        let packagePath = packageName.replacingOccurrences(of: ".", with: "/")
        let directory = declaringURL.deletingLastPathComponent()
        let path = directory.path
        let suffix = "/" + packagePath
        if path.hasSuffix(suffix) {
            let rootPath = String(path.dropLast(suffix.count))
            return URL(fileURLWithPath: rootPath, isDirectory: true)
        }
        return directory.deletingLastPathComponent()
    }

    private static func targetFileURL(
        declaringURL: URL, oldPackage: String, targetPackage: String, simpleName: String
    ) -> URL {
        let root = sourceRoot(of: declaringURL, packageName: oldPackage)
        let directory = targetPackage.isEmpty
            ? root
            : root.appendingPathComponent(targetPackage.replacingOccurrences(of: ".", with: "/"), isDirectory: true)
        return directory.appendingPathComponent("\(simpleName).java")
    }

    private static func filePackage(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^[ \t]*package[ \t]+([\w.]+)[ \t]*;"#),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges > 1 else { return "" }
        return (text as NSString).substring(with: match.range(at: 1))
    }

    private static func packageDeclarationEntry(
        in source: String, url: URL, oldPackage: String, newPackage: String
    ) -> WorkspaceEditPlanEntry? {
        let ns = source as NSString
        if newPackage.isEmpty {
            let pattern = #"(?m)^[ \t]*package[ \t]+[\w.]+[ \t]*;\n?"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) else {
                return nil
            }
            let oldText = ns.substring(with: match.range)
            let byteRange = JavaRenameProvider.byteRange(match.range, in: source)
            return JavaRefactoringText.planEntry(
                url: url, byteRange: byteRange, oldText: oldText, newText: "",
                source: source, description: "Remove package declaration"
            )
        }
        let pattern = #"(?m)^[ \t]*package[ \t]+([\w.]*)[ \t]*;"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) {
            let oldText = ns.substring(with: match.range)
            let newText = "package \(newPackage);"
            let byteRange = JavaRenameProvider.byteRange(match.range, in: source)
            return JavaRefactoringText.planEntry(
                url: url, byteRange: byteRange, oldText: oldText, newText: newText,
                source: source, description: "Update package"
            )
        }
        let insertion = "package \(newPackage);\n\n"
        return JavaRefactoringText.planEntry(
            url: url, byteRange: 0..<0, oldText: "", newText: insertion,
            source: source, description: "Insert package declaration"
        )
    }

    // MARK: - Reference edits

    private static func importEntry(
        usage: JavaUsage, source: String, url: URL,
        oldQualifiedName: String, newQualifiedName: String, readOnly: Bool
    ) -> WorkspaceEditPlanEntry? {
        guard let span = importReplacementSpan(
            usage: usage, source: source, oldQualifiedName: oldQualifiedName, newQualifiedName: newQualifiedName
        ) else { return nil }
        return WorkspaceEditPlanEntry(
            url: url.standardizedFileURL,
            range: JavaRefactoringText.textRange(for: span.range, in: source),
            oldText: span.oldText, newText: span.newText,
            lineText: usage.lineText, description: "Update import", isReadOnly: readOnly
        )
    }

    private static func referenceEntry(
        usage: JavaUsage, source: String, url: URL,
        oldQualifiedName: String, newQualifiedName: String, oldPackage: String, readOnly: Bool
    ) -> WorkspaceEditPlanEntry? {
        guard let span = referenceReplacementSpan(
            usage: usage, source: source, oldQualifiedName: oldQualifiedName,
            newQualifiedName: newQualifiedName, oldPackage: oldPackage
        ) else { return nil }
        guard span.oldText != span.newText else { return nil }
        return WorkspaceEditPlanEntry(
            url: url.standardizedFileURL,
            range: JavaRefactoringText.textRange(for: span.range, in: source),
            oldText: span.oldText, newText: span.newText,
            lineText: usage.lineText,
            description: usage.kind == .import ? "Update import" : "Update reference",
            isAmbiguous: usage.confidence == .ambiguous,
            isReadOnly: readOnly
        )
    }

    private struct TextSpan {
        let range: Range<Int>
        let oldText: String
        let newText: String
    }

    private static func importReplacementSpan(
        usage: JavaUsage, source: String, oldQualifiedName: String, newQualifiedName: String
    ) -> TextSpan? {
        let ns = source as NSString
        let lineRange = ns.lineRange(for: usage.utf16Range)
        let line = ns.substring(with: lineRange)
        guard line.contains("import"), line.contains(oldQualifiedName) else { return nil }
        guard let replaced = line.replacingOccurrences(of: oldQualifiedName, with: newQualifiedName) as String?,
              replaced != line else { return nil }
        let start = JavaNavigationText.utf8ByteOffset(forUTF16Offset: lineRange.location, in: source)
        let end = JavaNavigationText.utf8ByteOffset(forUTF16Offset: lineRange.location + lineRange.length, in: source)
        return TextSpan(range: start..<end, oldText: line, newText: replaced)
    }

    private static func referenceReplacementSpan(
        usage: JavaUsage, source: String, oldQualifiedName: String, newQualifiedName: String, oldPackage: String
    ) -> TextSpan? {
        let simpleName = String(oldQualifiedName.split(separator: ".").last ?? "")
        let bytes = Array(source.utf8)
        let tokenStart = usage.byteRange.lowerBound
        let tokenEnd = usage.byteRange.upperBound
        guard tokenEnd <= bytes.count else { return nil }

        if usage.kind == .import {
            return importReplacementSpan(
                usage: usage, source: source, oldQualifiedName: oldQualifiedName, newQualifiedName: newQualifiedName
            )
        }

        if tokenStart > 0, bytes[tokenStart - 1] == 46 {
            var qualStart = tokenStart - 1
            while qualStart > 0, isIdentByte(bytes[qualStart - 1]) { qualStart -= 1 }
            let oldText = String(decoding: bytes[qualStart..<tokenEnd], as: UTF8.self)
            if oldText == oldQualifiedName || oldText == oldPackage + "." + simpleName {
                let newText = newQualifiedName
                return TextSpan(range: qualStart..<tokenEnd, oldText: oldText, newText: newText)
            }
        }

        let oldText = String(decoding: bytes[tokenStart..<tokenEnd], as: UTF8.self)
        guard oldText == simpleName else { return nil }
        return TextSpan(range: tokenStart..<tokenEnd, oldText: oldText, newText: simpleName)
    }

    private static func moveJavadocUsages(
        stub: JavaClassStub, oldQualifiedName: String, newQualifiedName: String, in text: String, url: URL
    ) -> [JavaUsage] {
        let escapedOld = NSRegularExpression.escapedPattern(for: oldQualifiedName)
        let escapedSimple = NSRegularExpression.escapedPattern(for: stub.simpleName)
        guard text.contains("/**"),
              let comments = try? NSRegularExpression(pattern: #"/\*\*[\s\S]*?\*/"#),
              let tags = try? NSRegularExpression(
                pattern: #"@(?:link|linkplain|see|throws|exception|value)\s+(?:[A-Za-z_$][\w$]*\.)*("# + escapedOld + #"|"# + escapedSimple + #")(?![\w$])"#
              ),
              let tree = JavaSyntaxParser().parse(text) else { return [] }
        let ns = text as NSString
        let locator = JavaUsageLocator(url: url, text: text)
        var result: [JavaUsage] = []
        for comment in comments.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let start = JavaRenameProvider.byteRange(NSRange(location: comment.range.location, length: 0), in: text).lowerBound
            guard tree.node(atByteOffset: start).type.contains("comment") else { continue }
            for tag in tags.matches(in: text, range: comment.range) {
                result.append(locator.usage(
                    byteRange: JavaRenameProvider.byteRange(tag.range(at: 1), in: text),
                    kind: .typeReference, confidence: .exact
                ))
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func identifierRange(at offset: Int, in source: String) -> Range<Int>? {
        guard let tree = JavaSyntaxParser().parse(source) else { return nil }
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: offset, in: source)
        func isName(_ node: SyntaxNode) -> Bool { node.type == "identifier" || node.type == "type_identifier" }
        let leaf = tree.node(atByteOffset: byteOffset)
        if leaf.byteRange.contains(byteOffset), isName(leaf) { return leaf.byteRange }
        let before = tree.node(atByteOffset: max(0, byteOffset - 1))
        guard isName(before), before.byteRange.upperBound == byteOffset else { return nil }
        return before.byteRange
    }

    private static func isIdentByte(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95 || byte == 36
            || (byte >= 48 && byte <= 57)
    }

    private static func readText(of file: URL, environment: JavaReferenceEnvironment) async -> String? {
        if let reader = environment.openBuffer, let text = await reader(file) { return text }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    private static func blocked(_ message: String) -> WorkspaceEditPlan {
        WorkspaceEditPlan(blockingError: message, title: title)
    }
}
