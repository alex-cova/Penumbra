import EditorIntelligence
import Foundation

/// Safe rename for Java. Classes, interfaces, enums, records, annotations (top-level and nested),
/// locals and parameters are supported; members (methods, fields) are not yet.
///
/// The provider resolves the symbol under the caret to a ``JavaSymbolID`` and dispatches on it
/// (`symbolTarget(for:source:)` and the switches in `prepareRename`/`rename`), so support for
/// another kind of symbol is a new case there. Type renames search the project through a
/// ``JavaUsageCandidateSource`` (the persistent name index or the text-scan fallback), then add
/// the edits the resolver does not report: single-type and static imports, and Javadoc references.
public actor JavaRenameProvider: RenameProviding {
    private let index: JavaIndex
    private let cacheRoot: URL
    private let candidates: any JavaUsageCandidateSource
    private var roots: [URL] = []
    private var readOnlyRoots: [URL] = []
    private var gradleModel: JavaGradleProjectModel?
    private var indexPaths: JavaIndexPaths?
    private var jdkHome: URL?
    private var openBuffer: (@Sendable (URL) async -> String?)?

    public init(index: JavaIndex, indexPaths: JavaIndexPaths, candidates: any JavaUsageCandidateSource) {
        self.index = index
        self.cacheRoot = indexPaths.root
        self.candidates = candidates
        self.indexPaths = indexPaths
    }

    /// Project source roots searched for usages.
    public func setRoots(_ roots: [URL]) { self.roots = roots.map(\.standardizedFileURL) }
    /// Directories whose files must never be edited (generated sources).
    public func setReadOnlyRoots(_ roots: [URL]) { readOnlyRoots = roots.map(\.standardizedFileURL) }
    public func setGradleModel(_ model: JavaGradleProjectModel?) { gradleModel = model }
    public func setJDKHome(_ home: URL?) { jdkHome = home }
    public func setOpenBufferLookup(_ lookup: (@Sendable (URL) async -> String?)?) { openBuffer = lookup }

    // MARK: - RenameProviding

    public func prepareRename(_ context: NavigationContext) async -> RenameTarget? {
        guard context.document.languageIdentifier == "java" else { return nil }
        let source = JavaNavigationText.fullText(of: context.document)
        guard !source.isEmpty,
              let (token, id) = await symbolTarget(for: context, source: source) else { return nil }
        let description: String
        switch id {
        case .local: description = "variable"
        case .type(let qualifiedName):
            description = await index.classStub(qualifiedName: qualifiedName).map { Self.description(of: $0.kind) } ?? "class"
        default: return nil
        }
        return RenameTarget(
            range: JavaNavigationText.textRange(for: token, in: source),
            currentName: Self.text(of: token, in: source), kindDescription: description, validate: Self.validate
        )
    }

    public func rename(_ context: NavigationContext, to newName: String) async throws -> RenamePlan {
        let source = JavaNavigationText.fullText(of: context.document)
        if let problem = Self.validate(newName) { return RenamePlan(blockingError: problem) }
        guard let (token, id) = await symbolTarget(for: context, source: source) else {
            return RenamePlan(blockingError: "There is nothing here that can be renamed.")
        }
        if Self.text(of: token, in: source) == newName {
            return RenamePlan(blockingError: "The new name is the same as the current one.")
        }
        let environment = makeEnvironment(for: context)
        switch id {
        case .local:
            return localPlan(id, source: source, url: context.document.url, newName: newName)
        case .type(let qualifiedName):
            return await typePlan(qualifiedName, newName: newName, context: context, environment: environment)
        default:
            return RenamePlan(blockingError: "Renaming this kind of symbol is not supported yet.")
        }
    }

    // MARK: - Symbol resolution

    private func makeEnvironment(for context: NavigationContext) -> JavaReferenceEnvironment {
        let base = openBuffer
        let documentURL = context.document.url?.standardizedFileURL
        let documentText = JavaNavigationText.fullText(of: context.document)
        let lookup: @Sendable (URL) async -> String? = { url in
            if let documentURL, url.standardizedFileURL.path == documentURL.path, !documentText.isEmpty { return documentText }
            return await base?(url)
        }
        return JavaReferenceEnvironment(
            index: index, jdkHome: jdkHome, cacheRoot: cacheRoot, openBuffer: lookup,
            gradleModel: gradleModel, indexPaths: indexPaths
        )
    }

    /// The identifier under the caret (UTF-8 byte range) and the renamable symbol it denotes.
    /// A constructor stands for its type.
    private func symbolTarget(for context: NavigationContext, source: String) async -> (Range<Int>, JavaSymbolID)? {
        let offset = context.cursor.position.utf16Offset
        guard let tokenRange = Self.identifierRange(at: offset, in: source) else { return nil }
        let environment = makeEnvironment(for: context)
        guard var id = await JavaSymbolIdentity.symbolID(
            at: offset, in: source, url: context.document.url, environment: environment
        ) else { return nil }
        if case .constructor(let declaringClass, _) = id { id = .type(qualifiedName: declaringClass) }
        let name = Self.text(of: tokenRange, in: source)
        switch id {
        case .local: break
        case .type(let qualifiedName):
            guard String(qualifiedName.split(separator: ".").last ?? "") == name else { return nil }
        default:
            // Members (methods, fields): a later extension adds their cases here and in `rename`.
            return nil
        }
        return (tokenRange, id)
    }

    /// The identifier at (or just before) a UTF-16 offset, as a UTF-8 byte range.
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

    // MARK: - Locals

    private func localPlan(_ id: JavaSymbolID, source: String, url: URL?, newName: String) -> RenamePlan {
        guard case .local(let file, _) = id else { return RenamePlan() }
        let target = url ?? file
        let usages = JavaLocalUsages.usages(of: id, in: source)
        return RenamePlan(entries: usages.map { entry(for: $0, url: target, newName: newName, readOnly: false) })
    }

    // MARK: - Types

    private func typePlan(
        _ qualifiedName: String, newName: String, context: NavigationContext, environment: JavaReferenceEnvironment
    ) async -> RenamePlan {
        let simpleName = String(qualifiedName.split(separator: ".").last ?? "")
        guard let stub = await index.classStub(qualifiedName: qualifiedName) else {
            return RenamePlan(blockingError: "\(simpleName) could not be found in the project index.")
        }
        guard case .source(let declaringFile, _) = stub.origin else {
            return RenamePlan(blockingError: "\(simpleName) is declared in a library and cannot be renamed.")
        }
        let declaringURL = declaringFile.standardizedFileURL
        if isReadOnly(declaringURL) {
            return RenamePlan(blockingError: "\(simpleName) is declared in generated code and cannot be renamed.")
        }

        var plan = RenamePlan()
        if let conflict = await conflictWarning(for: stub, newName: newName) { plan.warnings.append(conflict) }

        let searchRoots = roots.isEmpty ? [declaringURL] : roots
        let id = JavaSymbolID.type(qualifiedName: qualifiedName)
        var usages = await JavaUsageSearch.collect(
            id, candidates: candidates, roots: searchRoots, environment: environment, includeDeclarations: true
        )
        var seenFiles = Set(usages.map { $0.url.standardizedFileURL.path })
        // The declaring file and the open document count even when outside the searched roots.
        var extra = [declaringURL]
        if let documentURL = context.document.url?.standardizedFileURL { extra.append(documentURL) }
        for file in extra where seenFiles.insert(file.path).inserted {
            guard let text = await readText(of: file, environment: environment) else { continue }
            usages += await JavaFileUsageResolver.usages(of: id, source: text, url: file, environment: environment)
        }

        var seen = Set<String>()
        var entries: [RenamePlanEntry] = []
        func add(_ usage: JavaUsage) {
            let key = "\(usage.url.standardizedFileURL.path):\(usage.byteRange.lowerBound)"
            guard seen.insert(key).inserted else { return }
            entries.append(entry(for: usage, url: usage.url, newName: newName, readOnly: isReadOnly(usage.url)))
        }
        for usage in usages { add(usage) }

        // Imports and Javadoc references, which the resolver does not report.
        var fileSet = Set(await candidates.candidateFiles(containing: simpleName, in: searchRoots).map(\.standardizedFileURL))
        fileSet.insert(declaringURL)
        for file in fileSet.sorted(by: { $0.path < $1.path }) {
            guard let text = await readText(of: file, environment: environment), text.contains(simpleName) else { continue }
            for usage in Self.importUsages(qualifiedName: qualifiedName, in: text, url: file) { add(usage) }
            for usage in Self.javadocUsages(of: stub, in: text, url: file) { add(usage) }
        }
        plan.entries = entries.sorted {
            $0.url.path != $1.url.path ? $0.url.path < $1.url.path : $0.range.start.utf16Offset < $1.range.start.utf16Offset
        }

        if stub.outerQualifiedName == nil, stub.modifiers.contains(.publicFlag),
           declaringURL.deletingPathExtension().lastPathComponent == simpleName {
            let target = declaringURL.deletingLastPathComponent().appendingPathComponent("\(newName).java")
            if FileManager.default.fileExists(atPath: target.path) {
                plan.blockingError = "\(newName).java already exists in this folder."
            } else {
                plan.fileRenames.append((from: declaringURL, to: target))
            }
        }
        if plan.entries.contains(where: \.isReadOnly) {
            plan.warnings.append("Some usages are in generated files and will not be changed.")
        }
        return plan
    }

    private func conflictWarning(for stub: JavaClassStub, newName: String) async -> String? {
        if let outer = stub.outerQualifiedName {
            if await index.classStub(qualifiedName: "\(outer).\(newName)") != nil {
                return "\(outer) already has a nested type named \(newName)."
            }
            return nil
        }
        let sibling = stub.packageName.isEmpty ? newName : "\(stub.packageName).\(newName)"
        if await index.classStub(qualifiedName: sibling) != nil {
            let place = stub.packageName.isEmpty ? "the default package" : "package \(stub.packageName)"
            return "A type named \(newName) already exists in \(place)."
        }
        return nil
    }

    // MARK: - Import and Javadoc scanning

    /// The last segment of a type's name inside single-type and static imports of that type.
    static func importUsages(qualifiedName: String, in text: String, url: URL) -> [JavaUsage] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?m)^[ \t]*import[ \t]+(?:static[ \t]+)?([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)"#
        ) else { return [] }
        let ns = text as NSString
        let simpleLength = ((qualifiedName.split(separator: ".").last.map(String.init) ?? "") as NSString).length
        let locator = JavaUsageLocator(url: url, text: text)
        var result: [JavaUsage] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let nameRange = match.range(at: 1)
            let dotted = ns.substring(with: nameRange)
            guard dotted == qualifiedName || dotted.hasPrefix(qualifiedName + ".") else { continue }
            let start = nameRange.location + (qualifiedName as NSString).length - simpleLength
            result.append(locator.usage(
                byteRange: byteRange(NSRange(location: start, length: simpleLength), in: text),
                kind: .import, confidence: .exact
            ))
        }
        return result
    }

    /// `{@link Old}`, `@see pkg.Old#m`, `@throws Old`... inside doc comments of files that can see the type.
    static func javadocUsages(of stub: JavaClassStub, in text: String, url: URL) -> [JavaUsage] {
        let escaped = NSRegularExpression.escapedPattern(for: stub.simpleName)
        guard text.contains("/**"), canSee(stub, from: text, url: url),
              let comments = try? NSRegularExpression(pattern: #"/\*\*[\s\S]*?\*/"#),
              let tags = try? NSRegularExpression(
                pattern: #"@(?:link|linkplain|see|throws|exception|value)\s+(?:[A-Za-z_$][\w$]*\.)*("# + escaped + #")(?![\w$])"#
              ),
              let tree = JavaSyntaxParser().parse(text) else { return [] }
        let ns = text as NSString
        let locator = JavaUsageLocator(url: url, text: text)
        var result: [JavaUsage] = []
        for comment in comments.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let start = byteRange(NSRange(location: comment.range.location, length: 0), in: text).lowerBound
            guard tree.node(atByteOffset: start).type.contains("comment") else { continue }
            for tag in tags.matches(in: text, range: comment.range) {
                result.append(locator.usage(byteRange: byteRange(tag.range(at: 1), in: text), kind: .typeReference, confidence: .exact))
            }
        }
        return result
    }

    private static func canSee(_ stub: JavaClassStub, from text: String, url: URL) -> Bool {
        if case .source(let file, _) = stub.origin, file.standardizedFileURL.path == url.standardizedFileURL.path { return true }
        if text.contains(stub.qualifiedName) { return true }
        let package = firstMatch(#"(?m)^[ \t]*package[ \t]+([\w.]+)[ \t]*;"#, in: text) ?? ""
        if package == stub.packageName { return true }
        if !stub.packageName.isEmpty, text.contains("import \(stub.packageName).*;") { return true }
        if let outer = stub.outerQualifiedName, text.contains("import \(outer).*;") { return true }
        return false
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges > 1 else { return nil }
        return (text as NSString).substring(with: match.range(at: 1))
    }

    // MARK: - Helpers

    private func isReadOnly(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path.contains("/build/generated/") { return true }
        var directories = readOnlyRoots
        if let gradleModel { directories += gradleModel.existingGeneratedSourceDirectories.map(\.standardizedFileURL) }
        return directories.contains { path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
    }

    private func readText(of file: URL, environment: JavaReferenceEnvironment) async -> String? {
        if let reader = environment.openBuffer, let text = await reader(file) { return text }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    private func entry(for usage: JavaUsage, url: URL, newName: String, readOnly: Bool) -> RenamePlanEntry {
        let length = usage.utf16Range.length
        let start = TextPosition(line: usage.line, column: usage.column, utf16Offset: usage.utf16Range.location)
        let end = TextPosition(line: usage.line, column: usage.column + length, utf16Offset: usage.utf16Range.location + length)
        let line = usage.lineText as NSString
        let oldText = line.length >= usage.column + length
            ? line.substring(with: NSRange(location: usage.column, length: length)) : ""
        return RenamePlanEntry(
            url: url.standardizedFileURL, range: EditorIntelligence.TextRange(start: start, end: end),
            oldText: oldText, newText: newName, lineText: usage.lineText,
            isAmbiguous: usage.confidence == .ambiguous, isReadOnly: readOnly
        )
    }

    private static func byteRange(_ range: NSRange, in text: String) -> Range<Int> {
        let lower = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.location, in: text)
        let upper = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.location + range.length, in: text)
        return lower..<upper
    }

    private static func text(of byteRange: Range<Int>, in source: String) -> String {
        String(decoding: Array(source.utf8)[byteRange], as: UTF8.self)
    }

    private static func description(of kind: JavaTypeKind) -> String {
        switch kind {
        case .classKind: return "class"
        case .interfaceKind: return "interface"
        case .enumKind: return "enum"
        case .recordKind: return "record"
        case .annotationKind: return "annotation"
        }
    }

    private static let reservedWords: Set<String> = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue",
        "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "goto", "if",
        "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private",
        "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this",
        "throw", "throws", "transient", "try", "void", "volatile", "while", "true", "false", "null", "_"
    ]

    /// Identifier rules plus Java's reserved words and literals.
    @Sendable
    static func validate(_ name: String) -> String? {
        if let problem = RenameTarget.validateIdentifier(name) { return problem }
        if reservedWords.contains(name) { return "“\(name)” is a reserved word in Java" }
        return nil
    }
}
