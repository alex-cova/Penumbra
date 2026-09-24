import EditorIntelligence
import Foundation

/// Rename plans for methods, fields, enum constants and record components.
extension JavaRenameProvider {
    // MARK: - Methods

    /// Renames every declaration in the method's override family plus all its usages. A family that
    /// reaches a library (JAR/JDK) or generated declaration is blocked: the library method's name
    /// is not ours to change. Overloads are separated by the parameter keys of the symbol ID.
    func methodPlan(
        _ id: JavaSymbolID, newName: String, context: NavigationContext, environment: JavaReferenceEnvironment
    ) async -> RenamePlan {
        guard case .method(let declaringClass, let name, let keys) = id else { return RenamePlan() }
        let index = self.index
        let members = await scoped(environment, context) { await JavaMethodFamily.members(of: id, index: index) }
        if members.isEmpty {
            return RenamePlan(blockingError: "\(name) could not be found in the project index.")
        }
        var declaringFiles: [URL] = []
        for member in members {
            guard case .source(let file, _)? = member.origin else {
                let message = member.declaringClass == declaringClass
                    ? "\(name) is declared in a library and cannot be renamed."
                    : "\(name) overrides a library method (\(member.declaringClass)): cannot rename."
                return RenamePlan(blockingError: message)
            }
            if isReadOnly(file) {
                let message = member.declaringClass == declaringClass
                    ? "\(name) is declared in generated code and cannot be renamed."
                    : "\(name) overrides a method in generated code (\(member.declaringClass)): cannot rename."
                return RenamePlan(blockingError: message)
            }
            declaringFiles.append(file.standardizedFileURL)
        }

        var plan = RenamePlan()
        // Same signature already present in a family class or its hierarchy.
        var conflictClasses = Set<String>()
        for member in members {
            conflictClasses.formUnion(await JavaMemberLookup.supertypeClosure(of: member.declaringClass, index: index))
            conflictClasses.insert(member.declaringClass)
        }
        for cls in conflictClasses.sorted() {
            guard let stub = await index.classStub(qualifiedName: cls) else { continue }
            if stub.methods.contains(where: { !$0.isConstructor && $0.name == newName && JavaTypeKeys.keys(of: $0) == keys }) {
                plan.warnings.append("\(cls) already declares \(newName)(\(keys.joined(separator: ", "))).")
                break
            }
        }

        var targets = [id]
        for member in members {
            let memberID = JavaSymbolID.method(
                declaringClass: member.declaringClass, name: name, parameterKeys: JavaTypeKeys.keys(of: member.method)
            )
            if !targets.contains(memberID) { targets.append(memberID) }
        }
        let isStatic = members.contains { $0.method.modifiers.contains(.staticFlag) }
        plan.entries = await collectEntries(
            targets, oldName: name, newName: newName, declaringFiles: declaringFiles,
            staticImportOwners: isStatic ? members.map(\.declaringClass) : [],
            context: context, environment: environment
        )
        finish(&plan)
        return plan
    }

    // MARK: - Fields

    func fieldPlan(
        _ id: JavaSymbolID, newName: String, context: NavigationContext, environment: JavaReferenceEnvironment
    ) async -> RenamePlan {
        guard case .field(let declaringClass, let name) = id else { return RenamePlan() }
        let index = self.index
        guard let stub = await index.classStub(qualifiedName: declaringClass) else {
            return RenamePlan(blockingError: "\(name) could not be found in the project index.")
        }
        guard case .source(let file, _) = stub.origin else {
            return RenamePlan(blockingError: "\(name) is declared in a library and cannot be renamed.")
        }
        if isReadOnly(file) {
            return RenamePlan(blockingError: "\(name) is declared in generated code and cannot be renamed.")
        }
        var plan = RenamePlan()
        let hierarchy = await JavaMemberLookup.supertypeClosure(of: declaringClass, index: index)
        for cls in [declaringClass] + hierarchy.sorted().filter({ $0 != declaringClass }) {
            guard let candidate = await index.classStub(qualifiedName: cls) else { continue }
            if candidate.fields.contains(where: { $0.name == newName }) {
                plan.warnings.append("\(cls) already has a field named \(newName).")
                break
            }
        }
        // Getters and setters keep their names; tell the user they exist.
        let capitalized = name.prefix(1).uppercased() + name.dropFirst()
        let accessors = ["get", "set", "is"].map { $0 + capitalized }
        let present = Set(stub.methods.filter { accessors.contains($0.name) }.map(\.name))
        if !present.isEmpty {
            plan.warnings.append("\(present.sorted().joined(separator: ", ")) is not renamed with the field.")
        }

        var targets = [id]
        var declaringFiles = [file.standardizedFileURL]
        if stub.kind == .recordKind {
            // A record component also names its accessor: `x()` follows the component. An explicit
            // accessor joins the search through its family; the implicit one is searched by ID.
            let accessor = JavaSymbolID.method(declaringClass: declaringClass, name: name, parameterKeys: [])
            let members = await scoped(environment, context) { await JavaMethodFamily.members(of: accessor, index: index) }
            for member in members {
                guard case .source(let f, _)? = member.origin else {
                    return RenamePlan(blockingError: "\(name)() implements a library method: cannot rename the record component.")
                }
                declaringFiles.append(f.standardizedFileURL)
                targets.append(.method(
                    declaringClass: member.declaringClass, name: name, parameterKeys: JavaTypeKeys.keys(of: member.method)
                ))
            }
            if members.isEmpty { targets.append(accessor) }
        }
        plan.entries = await collectEntries(
            targets, oldName: name, newName: newName, declaringFiles: declaringFiles,
            staticImportOwners: [declaringClass], context: context, environment: environment
        )
        if await Self.fieldDescription(declaringClass: declaringClass, name: name, index: index) == "enum constant" {
            plan.entries = await addSwitchLabelEntries(
                plan.entries, owner: stub, oldName: name, newName: newName, context: context, environment: environment
            )
        }
        if stub.kind == .recordKind {
            plan.entries = await addCompactConstructorEntries(
                plan.entries, record: stub, oldName: name, newName: newName, environment: environment
            )
        }
        plan.warnings += await shadowWarnings(for: plan.entries, newName: newName, environment: environment)
        finish(&plan)
        return plan
    }

    static func fieldDescription(declaringClass: String, name: String, index: JavaIndex) async -> String {
        guard let stub = await index.classStub(qualifiedName: declaringClass) else { return "field" }
        if stub.kind == .recordKind { return "record component" }
        if stub.kind == .enumKind, let field = stub.fields.first(where: { $0.name == name }),
           case .classType(let type, _, _) = field.type, type == declaringClass {
            return "enum constant"
        }
        return "field"
    }

    // MARK: - Shared

    private func scoped<T: Sendable>(
        _ environment: JavaReferenceEnvironment, _ context: NavigationContext, _ body: @escaping () async -> T
    ) async -> T {
        guard let url = context.document.url else { return await body() }
        let scope = environment.queryScope(for: url)
        let reader = environment.openBuffer
        return await JavaIndex.$queryScope.withValue(scope) {
            await JavaMemberLookup.$sourceTextProvider.withValue(reader) {
                await body()
            }
        }
    }

    private func finish(_ plan: inout RenamePlan) {
        if plan.entries.contains(where: \.isReadOnly) {
            plan.warnings.append("Some usages are in generated files and will not be changed.")
        }
        let ambiguous = plan.entries.filter(\.isAmbiguous).count
        if ambiguous > 0 {
            plan.warnings.append(
                "\(ambiguous) usage\(ambiguous == 1 ? "" : "s") could not be resolved exactly and will not be changed unless selected."
            )
        }
    }

    private static func sorted(_ entries: [RenamePlanEntry]) -> [RenamePlanEntry] {
        entries.sorted {
            $0.url.path != $1.url.path ? $0.url.path < $1.url.path : $0.range.start.utf16Offset < $1.range.start.utf16Offset
        }
    }

    /// Usages of every target (declarations included) plus static imports, deduped and sorted.
    private func collectEntries(
        _ targets: [JavaSymbolID], oldName: String, newName: String, declaringFiles: [URL], staticImportOwners: [String],
        context: NavigationContext, environment: JavaReferenceEnvironment
    ) async -> [RenamePlanEntry] {
        let documentURL = context.document.url?.standardizedFileURL
        let extra = declaringFiles + [documentURL].compactMap { $0 }
        let searchRoots = roots.isEmpty ? extra : roots
        var usages: [JavaUsage] = []
        var seenFiles = Set<String>()
        for target in targets {
            let found = await JavaUsageSearch.collect(
                target, candidates: candidates, roots: searchRoots, environment: environment, includeDeclarations: true
            )
            usages += found
            for usage in found { seenFiles.insert(usage.url.standardizedFileURL.path) }
        }
        // Declaring files and the open document count even when outside the searched roots.
        for file in extra where seenFiles.insert(file.path).inserted {
            guard let text = await readText(of: file, environment: environment) else { continue }
            for target in targets {
                usages += await JavaFileUsageResolver.usages(of: target, source: text, url: file, environment: environment)
            }
        }

        var seen = Set<String>()
        var entries: [RenamePlanEntry] = []
        func add(_ usage: JavaUsage) {
            let key = "\(usage.url.standardizedFileURL.path):\(usage.byteRange.lowerBound)"
            guard seen.insert(key).inserted else { return }
            entries.append(entry(for: usage, url: usage.url, newName: newName, readOnly: isReadOnly(usage.url)))
        }
        for usage in usages { add(usage) }

        if !staticImportOwners.isEmpty {
            var files = Set(await candidates.candidateFiles(containing: oldName, in: searchRoots).map(\.standardizedFileURL))
            for file in extra { files.insert(file) }
            for file in files.sorted(by: { $0.path < $1.path }) {
                guard let text = await readText(of: file, environment: environment), text.contains("import static") else { continue }
                for owner in Set(staticImportOwners) {
                    for usage in Self.staticImportUsages(owner: owner, member: oldName, in: text, url: file) { add(usage) }
                }
            }
        }
        return Self.sorted(entries)
    }

    /// The member name inside `import static pkg.Owner.member;` (wildcard imports need no edit).
    static func staticImportUsages(owner: String, member: String, in text: String, url: URL) -> [JavaUsage] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?m)^[ \t]*import[ \t]+static[ \t]+([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)"#
        ) else { return [] }
        let ns = text as NSString
        let locator = JavaUsageLocator(url: url, text: text)
        let length = (member as NSString).length
        var result: [JavaUsage] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let nameRange = match.range(at: 1)
            guard ns.substring(with: nameRange) == "\(owner).\(member)" else { continue }
            let start = nameRange.location + nameRange.length - length
            result.append(locator.usage(
                byteRange: byteRange(NSRange(location: start, length: length), in: text), kind: .import, confidence: .exact
            ))
        }
        return result
    }

    /// `case RED:` labels name an enum constant without a qualifier, and the usage resolver does not
    /// type the switch selector. The label is exact when no other project enum has a constant of
    /// that name; otherwise it is flagged ambiguous so the preview asks the user.
    private func addSwitchLabelEntries(
        _ entries: [RenamePlanEntry], owner: JavaClassStub, oldName: String, newName: String,
        context: NavigationContext, environment: JavaReferenceEnvironment
    ) async -> [RenamePlanEntry] {
        let others = await index.projectClassStubs().filter {
            $0.kind == .enumKind && $0.qualifiedName != owner.qualifiedName && $0.fields.contains { $0.name == oldName }
        }
        let confidence: JavaUsage.Confidence = others.isEmpty ? .exact : .ambiguous
        var files = Set(await candidates.candidateFiles(containing: oldName, in: roots).map(\.standardizedFileURL))
        if case .source(let file, _) = owner.origin { files.insert(file.standardizedFileURL) }
        if let url = context.document.url { files.insert(url.standardizedFileURL) }
        var result = entries
        var seen = Set(entries.map { "\($0.url.standardizedFileURL.path):\($0.range.start.utf16Offset)" })
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard let text = await readText(of: file, environment: environment), text.contains("case"),
                  let tree = JavaSyntaxParser().parse(text) else { continue }
            let locator = JavaUsageLocator(url: file, text: text)
            func walk(_ node: SyntaxNode) {
                if node.type == "switch_label" {
                    for child in node.namedChildren where child.type == "identifier" && child.text == oldName {
                        let usage = locator.usage(byteRange: child.byteRange, kind: .read, confidence: confidence)
                        if seen.insert("\(file.path):\(usage.utf16Range.location)").inserted {
                            result.append(entry(for: usage, url: file, newName: newName, readOnly: isReadOnly(file)))
                        }
                    }
                }
                for child in node.namedChildren { walk(child) }
            }
            walk(tree.rootNode)
        }
        return Self.sorted(result)
    }

    /// In a compact canonical constructor the component names are implicit parameters; their uses
    /// in the body are the component and follow it.
    private func addCompactConstructorEntries(
        _ entries: [RenamePlanEntry], record: JavaClassStub, oldName: String, newName: String,
        environment: JavaReferenceEnvironment
    ) async -> [RenamePlanEntry] {
        guard case .source(let file, _) = record.origin,
              let text = await readText(of: file, environment: environment),
              let tree = JavaSyntaxParser().parse(text) else { return entries }
        var found: [JavaUsage] = []
        let locator = JavaUsageLocator(url: file, text: text)
        func walk(_ node: SyntaxNode, inCompact: Bool) {
            var inside = inCompact
            if node.type == "compact_constructor_declaration" {
                inside = node.child(byFieldName: "name")?.text == record.simpleName
            }
            if inside, node.type == "identifier", node.text == oldName, let parent = node.parent,
               parent.type != "compact_constructor_declaration",
               !(parent.type == "field_access" && parent.child(byFieldName: "field")?.byteRange == node.byteRange),
               !(parent.type == "method_invocation" && parent.child(byFieldName: "name")?.byteRange == node.byteRange) {
                found.append(locator.usage(byteRange: node.byteRange, kind: .read, confidence: .exact))
            }
            for child in node.namedChildren { walk(child, inCompact: inside) }
        }
        walk(tree.rootNode, inCompact: false)
        var result = entries
        var seen = Set(entries.map { "\($0.url.standardizedFileURL.path):\($0.range.start.utf16Offset)" })
        for usage in found where seen.insert("\(file.standardizedFileURL.path):\(usage.utf16Range.location)").inserted {
            result.append(entry(for: usage, url: file, newName: newName, readOnly: isReadOnly(file)))
        }
        return Self.sorted(result)
    }

    /// A local or parameter already called `newName` in the method around an unqualified use of the
    /// renamed field would capture it.
    private func shadowWarnings(
        for entries: [RenamePlanEntry], newName: String, environment: JavaReferenceEnvironment
    ) async -> [String] {
        var warnings: [String] = []
        let byFile = Dictionary(grouping: entries.filter { !$0.isReadOnly }, by: { $0.url.standardizedFileURL })
        let scopes: Set<String> = ["method_declaration", "constructor_declaration", "compact_constructor_declaration", "lambda_expression"]
        for file in byFile.keys.sorted(by: { $0.path < $1.path }) {
            guard let text = await readText(of: file, environment: environment),
                  let tree = JavaSyntaxParser().parse(text) else { continue }
            for entry in byFile[file] ?? [] {
                let byte = JavaNavigationText.utf8ByteOffset(forUTF16Offset: entry.range.start.utf16Offset, in: text)
                let leaf = tree.node(atByteOffset: byte)
                guard leaf.type == "identifier", let parent = leaf.parent else { continue }
                switch parent.type {
                case "field_access":
                    if parent.child(byFieldName: "field")?.byteRange == leaf.byteRange { continue }
                case "method_invocation", "method_reference", "variable_declarator", "formal_parameter", "record_declaration":
                    continue
                default: break
                }
                var scope: SyntaxNode? = leaf
                while let current = scope, !scopes.contains(current.type) { scope = current.parent }
                if let scope, Self.declaresLocal(named: newName, in: scope) {
                    warnings.append("A local variable or parameter named \(newName) in \(file.lastPathComponent) would shadow the renamed field.")
                    break
                }
            }
        }
        return warnings
    }

    private static func declaresLocal(named name: String, in node: SyntaxNode) -> Bool {
        switch node.type {
        case "formal_parameter", "spread_parameter", "catch_formal_parameter", "variable_declarator", "resource":
            if node.child(byFieldName: "name")?.text == name { return true }
        default: break
        }
        return node.namedChildren.contains { declaresLocal(named: name, in: $0) }
    }
}
