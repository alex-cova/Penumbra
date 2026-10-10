import EditorIntelligence
import Foundation

/// Project Swift files, indexed off the keystroke path. A query reads an open buffer's text when
/// the host has one and the indexed tree otherwise, so what a user typed but did not save is seen.
///
/// Names are looked up by simple name and filtered by module: a file sees its own module and the
/// modules it imports. Without a module map (no SwiftPM model) every file is one module. The
/// standard library and the SDK are not indexed, so a type from them has no members here.
public actor SwiftIndex {
    public init() {}
    public struct TypeRef: Sendable {
        public var url: URL
        public var declaration: SwiftFileModel.Declaration
        public var module: String?
    }

    public struct MemberRef: Sendable {
        public var url: URL
        public var declaration: SwiftFileModel.Declaration
        /// The type the member was found through, which is the declaring type or the extended one.
        public var owner: String
        public var isInExtension: Bool
    }

    public struct ExportRef: Sendable {
        public var name: String
        public var url: URL
        public var kind: SwiftFileModel.Kind
        public var signature: String
        public var module: String?
    }

    public struct PaletteSymbol: Sendable, Equatable {
        public var name: String
        public var container: String
        public var url: URL
        public var kind: SwiftFileModel.Kind
        public var nameBytes: Range<Int>
    }

    public struct ExternalUse: Sendable {
        public var url: URL
        public var source: String
        public var ranges: [Range<Int>]
    }

    private var root: URL?
    private var generation = 0
    private var buildingToken: Int?
    private var pendingEdits: [URL: SwiftFileModel?] = [:]
    private var files: [URL: SwiftFileModel] = [:]
    private var moduleByFile: [URL: String] = [:]
    private var moduleResolver: (@Sendable (URL) -> String?)?
    private var bufferHashes: [URL: Int] = [:]
    private var openBuffer: (@Sendable (URL) async -> String?)?

    private var typesByName: [String: [TypeRef]] = [:]
    private var extensionsByName: [String: [TypeRef]] = [:]
    private var topLevelByName: [String: [TypeRef]] = [:]
    private var subtypesByName: [String: [TypeRef]] = [:]
    private var names: [String: Set<URL>] = [:]
    private var symbolsByFile: [URL: [PaletteSymbol]] = [:]

    // MARK: Configuration

    public func setOpenBufferLookup(_ lookup: (@Sendable (URL) async -> String?)?) {
        openBuffer = lookup
    }

    /// Tells the index which module a file belongs to (SwiftPM target directories). Applies to
    /// every file at once and to the ones indexed afterwards.
    public func setModuleResolver(_ resolver: (@Sendable (URL) -> String?)?) {
        moduleResolver = resolver
        let snapshot = files
        clearTables()
        for (url, model) in snapshot { add(url, model) }
    }

    public func module(of url: URL) -> String? {
        moduleByFile[url.standardizedFileURL]
    }

    // MARK: Building

    /// Rebuilds the index for `root` (or clears it). A newer call wins; a cancelled one does not publish.
    public func setRoot(_ root: URL?) async {
        if Task.isCancelled { return }
        generation += 1
        let token = generation
        buildingToken = token
        pendingEdits = [:]
        let standardized = root?.standardizedFileURL
        self.root = standardized
        guard let standardized else {
            replaceAll([:])
            buildingToken = nil
            return
        }
        let urls = await Task.detached { SwiftIndex.enumerate(standardized) }.value
        guard token == generation, !Task.isCancelled else {
            if buildingToken == token { buildingToken = nil }
            return
        }
        let parsed = await parseAll(urls)
        guard token == generation, !Task.isCancelled else {
            if buildingToken == token { buildingToken = nil }
            return
        }
        var merged = parsed
        for (url, edit) in pendingEdits {
            if let edit { merged[url] = edit } else { merged.removeValue(forKey: url) }
        }
        replaceAll(merged)
        pendingEdits = [:]
        buildingToken = nil
    }

    public func applyFileChanges(_ urls: [URL]) {
        for url in urls {
            let standardized = url.standardizedFileURL
            guard SwiftPaths.isSourceFile(standardized), !SwiftPaths.isSkipped(standardized) else { continue }
            let model: SwiftFileModel?
            if FileManager.default.fileExists(atPath: standardized.path), let source = Self.readDisk(standardized) {
                model = SwiftAnalysis.parseModel(source)
            } else {
                model = nil
            }
            if buildingToken != nil { pendingEdits[standardized] = model }
            bufferHashes[standardized] = nil
            remove(standardized)
            if let model { add(standardized, model) }
        }
    }

    /// The editor has `text` open for `url`. A changed buffer replaces the file's entry, so a member
    /// typed a moment ago is found without a save.
    public func noteOpenDocument(url: URL, text: String) {
        let standardized = url.standardizedFileURL
        guard SwiftPaths.isSourceFile(standardized), !SwiftPaths.isSkipped(standardized) else { return }
        let key = text.hashValue
        if bufferHashes[standardized] == key, files[standardized] != nil { return }
        guard let parsed = SwiftAnalysis.parse(text) else { return }
        bufferHashes[standardized] = key
        remove(standardized)
        add(standardized, parsed.model)
    }

    public func contains(_ url: URL) -> Bool {
        files[url.standardizedFileURL] != nil
    }

    public var fileCount: Int { files.count }

    public func model(for url: URL) async -> SwiftFileModel? {
        let standardized = url.standardizedFileURL
        await refresh(standardized)
        return files[standardized]
    }

    /// The text the editor shows for `url`, else the file on disk when it is indexed.
    public func source(for url: URL) async -> String? {
        let standardized = url.standardizedFileURL
        if let openBuffer {
            if let text = await openBuffer(standardized) { return text }
            if standardized != url, let text = await openBuffer(url) { return text }
        }
        return files[standardized] == nil ? nil : Self.readDisk(standardized)
    }

    private func refresh(_ url: URL) async {
        guard let openBuffer, SwiftPaths.isSourceFile(url) else { return }
        guard let text = await openBuffer(url) else { return }
        noteOpenDocument(url: url, text: text)
    }

    // MARK: Lookups

    /// Files that declare or extend `name`, so they can be refreshed from open buffers first.
    private func declaringFiles(of name: String) -> Set<URL> {
        var result = Set<URL>()
        for ref in typesByName[name] ?? [] { result.insert(ref.url) }
        for ref in extensionsByName[name] ?? [] { result.insert(ref.url) }
        return result
    }

    /// Nominal types and typealiases named `name` that `file` can see.
    public func types(named name: String, visibleFrom file: URL?) async -> [TypeRef] {
        for url in declaringFiles(of: name) { await refresh(url) }
        return visible(typesByName[name] ?? [], from: file)
    }

    public func topLevel(named name: String, visibleFrom file: URL?) async -> [TypeRef] {
        for ref in topLevelByName[name] ?? [] { await refresh(ref.url) }
        return visible(topLevelByName[name] ?? [], from: file)
    }

    /// Types and extensions that list `name` as a superclass or protocol.
    public func subtypes(of name: String, visibleFrom file: URL?) async -> [TypeRef] {
        visible(subtypesByName[name] ?? [], from: file)
    }

    /// Every type and extension below `name`: its subtypes, theirs in turn, up to `limit`.
    public func descendants(of name: String, visibleFrom file: URL?, limit: Int = 200) -> [TypeRef] {
        var result: [TypeRef] = []
        var queue = [name]
        var seen: Set<String> = [name]
        while !queue.isEmpty, result.count < limit {
            let current = queue.removeFirst()
            for ref in visible(subtypesByName[current] ?? [], from: file) {
                result.append(ref)
                if seen.insert(ref.declaration.name).inserted { queue.append(ref.declaration.name) }
            }
        }
        return result
    }

    /// Direct supertypes of `name`: what its declaration and its extensions list.
    public func supertypes(of name: String, visibleFrom file: URL?) async -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for ref in visible((typesByName[name] ?? []) + (extensionsByName[name] ?? []), from: file) {
            for inherited in ref.declaration.inherits where seen.insert(inherited).inserted {
                result.append(inherited)
            }
        }
        return result
    }

    /// The members of `name` and of everything it inherits or conforms to, with extensions merged.
    /// A member the type declares shadows an inherited one of the same name and labels. A
    /// `private` member is listed only to the file that declares it.
    public func members(ofType name: String, visibleFrom file: URL?) async -> [MemberRef] {
        var reached: [String] = []
        var queue = [name]
        var seen = Set<String>()
        while !queue.isEmpty, seen.count < 64 {
            let current = queue.removeFirst()
            guard seen.insert(current).inserted else { continue }
            reached.append(current)
            for url in declaringFiles(of: current) { await refresh(url) }
            for ref in visible((typesByName[current] ?? []) + (extensionsByName[current] ?? []), from: file) {
                if ref.declaration.kind == .typeAlias, let target = ref.declaration.typeName { queue.append(target) }
                queue.append(contentsOf: ref.declaration.inherits)
            }
        }
        var result: [MemberRef] = []
        var keys = Set<String>()
        let current = file?.standardizedFileURL
        for typeName in reached {
            let refs = visible(typesByName[typeName] ?? [], from: file) + visible(extensionsByName[typeName] ?? [], from: file)
            for ref in refs {
                for member in ref.declaration.members {
                    if member.access <= .fileprivate, ref.url != current { continue }
                    if member.kind.isNominalType || member.kind == .extension { continue }
                    let key = "\(member.kind.rawValue):\(member.name):\(member.parameters.map { $0.label ?? "_" }.joined(separator: ","))"
                    guard keys.insert(key).inserted else { continue }
                    result.append(MemberRef(
                        url: ref.url, declaration: member, owner: typeName,
                        isInExtension: ref.declaration.kind == .extension
                    ))
                }
            }
        }
        return result
    }

    /// The members `name` and its extensions declare themselves, with nothing inherited.
    public func declaredMembers(ofType name: String, visibleFrom file: URL?) async -> [MemberRef] {
        for url in declaringFiles(of: name) { await refresh(url) }
        var result: [MemberRef] = []
        for ref in visible(typesByName[name] ?? [], from: file) {
            for member in ref.declaration.members where !member.kind.isNominalType && member.kind != .extension {
                result.append(MemberRef(url: ref.url, declaration: member, owner: name, isInExtension: false))
            }
        }
        for ref in visible(extensionsByName[name] ?? [], from: file) {
            for member in ref.declaration.members where !member.kind.isNominalType && member.kind != .extension {
                result.append(MemberRef(url: ref.url, declaration: member, owner: name, isInExtension: true))
            }
        }
        return result
    }

    /// Types nested in `name`.
    public func nestedTypes(in name: String, visibleFrom file: URL?) async -> [TypeRef] {
        var result: [TypeRef] = []
        for ref in visible((typesByName[name] ?? []) + (extensionsByName[name] ?? []), from: file) {
            for member in ref.declaration.members where member.kind.isNominalType || member.kind == .typeAlias {
                result.append(TypeRef(url: ref.url, declaration: member, module: ref.module))
            }
        }
        return result
    }

    /// Project declarations whose names match `prefix`, for completion across files and modules.
    public func exports(matching prefix: String, limit: Int) -> [ExportRef] {
        var matches: [ExportRef] = []
        func scan(_ table: [String: [TypeRef]]) {
            for (name, refs) in table where prefix.isEmpty || (CompletionMatcher.couldMatch(prefix, name) && CompletionMatcher.matches(prefix, name)) {
                for ref in refs where ref.declaration.access > .fileprivate {
                    matches.append(ExportRef(
                        name: name, url: ref.url, kind: ref.declaration.kind,
                        signature: ref.declaration.signature, module: ref.module
                    ))
                }
                if matches.count >= limit { return }
            }
        }
        scan(typesByName)
        if matches.count < limit { scan(topLevelByName) }
        if matches.count > limit { matches.removeSubrange(limit...) }
        return matches
    }

    /// Files that mention `name` anywhere, a superset of the files that use the symbol.
    public func candidateFiles(mentioning name: String) -> Set<URL> {
        names[name] ?? []
    }

    /// Types and members whose names match `query`, in index order, up to `limit`.
    public func symbols(matching query: String, limit: Int) -> [PaletteSymbol] {
        guard limit > 0, !query.isEmpty else { return [] }
        var matches: [PaletteSymbol] = []
        for symbols in symbolsByFile.values {
            for symbol in symbols {
                guard CompletionMatcher.couldMatch(query, symbol.name),
                      CompletionMatcher.matches(query, symbol.name) else { continue }
                matches.append(symbol)
                if matches.count == limit { return matches }
            }
        }
        return matches
    }

    /// Every nominal type and typealias in the project, for the hierarchy and diagram code.
    public func allTypeDeclarations() -> [TypeRef] {
        typesByName.values.flatMap { $0 }
    }

    // MARK: Visibility

    private func visible(_ refs: [TypeRef], from file: URL?) -> [TypeRef] {
        guard !refs.isEmpty else { return refs }
        guard let file else { return refs }
        let standardized = file.standardizedFileURL
        let own = moduleByFile[standardized]
        let imported = Set((files[standardized]?.imports ?? []).map(\.module))
        return refs.filter { ref in
            guard let module = ref.module, let own else { return true }
            return module == own || imported.contains(module)
        }
    }

    // MARK: Publishing

    private func clearTables() {
        typesByName = [:]
        extensionsByName = [:]
        topLevelByName = [:]
        subtypesByName = [:]
        names = [:]
        symbolsByFile = [:]
        moduleByFile = [:]
    }

    private func replaceAll(_ models: [URL: SwiftFileModel]) {
        files = [:]
        bufferHashes = [:]
        clearTables()
        for (url, model) in models { add(url, model) }
    }

    private func add(_ url: URL, _ full: SwiftFileModel) {
        let model = full.indexed()
        files[url] = model
        let module = moduleResolver?(url)
        moduleByFile[url] = module
        for declaration in model.declarations {
            register(declaration, url: url, module: module)
        }
        for name in model.identifiers {
            names[name, default: []].insert(url)
        }
        var symbols: [PaletteSymbol] = []
        collectPaletteSymbols(model.declarations, container: "", url: url, into: &symbols)
        symbolsByFile[url] = symbols
    }

    private func remove(_ url: URL) {
        guard let old = files.removeValue(forKey: url) else { return }
        moduleByFile[url] = nil
        symbolsByFile[url] = nil
        for name in old.identifiers {
            names[name]?.remove(url)
            if names[name]?.isEmpty == true { names[name] = nil }
        }
        func drop(_ table: inout [String: [TypeRef]], _ key: String) {
            table[key]?.removeAll { $0.url == url }
            if table[key]?.isEmpty == true { table[key] = nil }
        }
        func unregister(_ declaration: SwiftFileModel.Declaration) {
            switch declaration.kind {
            case .class, .struct, .enum, .actor, .protocol, .typeAlias:
                drop(&typesByName, declaration.name)
                for inherited in declaration.inherits { drop(&subtypesByName, inherited) }
            case .extension:
                drop(&extensionsByName, declaration.name)
                for inherited in declaration.inherits { drop(&subtypesByName, inherited) }
            default:
                if declaration.isTopLevel { drop(&topLevelByName, declaration.name) }
            }
            if declaration.kind.isNominalType || declaration.kind == .extension {
                declaration.members.forEach(unregister)
            }
        }
        old.declarations.forEach(unregister)
    }

    private func register(_ declaration: SwiftFileModel.Declaration, url: URL, module: String?) {
        let ref = TypeRef(url: url, declaration: declaration, module: module)
        switch declaration.kind {
        case .class, .struct, .enum, .actor, .protocol, .typeAlias:
            typesByName[declaration.name, default: []].append(ref)
            for inherited in declaration.inherits { subtypesByName[inherited, default: []].append(ref) }
        case .extension:
            extensionsByName[declaration.name, default: []].append(ref)
            for inherited in declaration.inherits { subtypesByName[inherited, default: []].append(ref) }
        default:
            if declaration.isTopLevel { topLevelByName[declaration.name, default: []].append(ref) }
        }
        if declaration.kind.isNominalType || declaration.kind == .extension {
            for member in declaration.members where member.kind.isNominalType || member.kind == .extension || member.kind == .typeAlias {
                register(member, url: url, module: module)
            }
        }
    }

    private func collectPaletteSymbols(
        _ declarations: [SwiftFileModel.Declaration], container: String, url: URL, into symbols: inout [PaletteSymbol]
    ) {
        for declaration in declarations {
            let include: Bool
            switch declaration.kind {
            case .class, .struct, .enum, .actor, .protocol, .typeAlias, .function, .property, .enumCase:
                include = !declaration.name.isEmpty
            default:
                include = false
            }
            if include {
                symbols.append(PaletteSymbol(
                    name: declaration.name, container: container, url: url,
                    kind: declaration.kind, nameBytes: declaration.nameBytes
                ))
            }
            if declaration.kind.isNominalType || declaration.kind == .extension {
                collectPaletteSymbols(declaration.members, container: declaration.name, url: url, into: &symbols)
            }
        }
    }

    // MARK: Disk

    private func parseAll(_ urls: [URL]) async -> [URL: SwiftFileModel] {
        let limit = 8
        return await withTaskGroup(of: (URL, SwiftFileModel)?.self) { group in
            var next = 0
            func add(_ url: URL) {
                group.addTask {
                    if Task.isCancelled { return nil }
                    guard let source = SwiftIndex.readDisk(url) else { return nil }
                    guard let model = SwiftAnalysis.parseModel(source) else { return nil }
                    return (url, model)
                }
            }
            while next < urls.count && next < limit {
                add(urls[next])
                next += 1
            }
            var result: [URL: SwiftFileModel] = [:]
            for await item in group {
                if let (url, model) = item { result[url] = model }
                if next < urls.count {
                    add(urls[next])
                    next += 1
                }
            }
            return result
        }
    }

    private static func enumerate(_ root: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var urls: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if SwiftPaths.skipDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard SwiftPaths.isSourceFile(url), !SwiftPaths.isSkipped(url) else { continue }
            if let size = values?.fileSize, size > SwiftPaths.maxBytes { continue }
            urls.append(url.standardizedFileURL)
        }
        return urls
    }

    private static func readDisk(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        guard data.count <= SwiftPaths.maxBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
