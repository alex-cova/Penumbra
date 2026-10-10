import EditorIntelligence
import Foundation

/// Project TypeScript files, indexed off the keystroke path. A query reads the open buffer when
/// the host has one and the indexed tree otherwise. Package names and `node_modules` are not resolved.
actor TypeScriptIndex {
    struct ExportRef: Sendable {
        var name: String
        var url: URL
        var kind: TypeScriptFileModel.Kind
        var signature: String
        var isTypeOnly: Bool
    }

    struct ExternalUse: Sendable {
        var url: URL
        var source: String
        var ranges: [Range<Int>]
    }

    private var root: URL?
    private var generation = 0
    private var buildingToken: Int?
    private var pendingEdits: [URL: TypeScriptFileModel?] = [:]
    private var files: [URL: TypeScriptFileModel] = [:]
    struct PaletteSymbol: Sendable, Equatable {
        var name: String
        var container: String
        var url: URL
        var kind: TypeScriptFileModel.Kind
        var nameBytes: Range<Int>
    }

    private var names: [String: Set<URL>] = [:]
    private var exportsByName: [String: [ExportRef]] = [:]
    private var paletteSymbols: [PaletteSymbol] = []
    private var openBuffer: (@Sendable (URL) async -> String?)?

    func setOpenBufferLookup(_ lookup: (@Sendable (URL) async -> String?)?) {
        openBuffer = lookup
    }

    /// Rebuilds the index for `root` (or clears it). A newer call wins; a cancelled one does not publish.
    func setRoot(_ root: URL?) async {
        if Task.isCancelled { return }
        generation += 1
        let token = generation
        buildingToken = token
        pendingEdits = [:]
        let standardized = root?.standardizedFileURL
        self.root = standardized
        guard let standardized else {
            publish([:])
            buildingToken = nil
            return
        }
        let urls = await Task.detached { TypeScriptIndex.enumerate(standardized) }.value
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
            if let edit {
                merged[url] = edit
            } else {
                merged.removeValue(forKey: url)
            }
        }
        publish(merged)
        pendingEdits = [:]
        buildingToken = nil
    }

    func applyFileChanges(_ urls: [URL]) async {
        for url in urls {
            let standardized = url.standardizedFileURL
            guard TypeScriptPaths.isSourceFile(standardized), !TypeScriptPaths.isSkipped(standardized) else { continue }
            let model: TypeScriptFileModel?
            if FileManager.default.fileExists(atPath: standardized.path), let source = Self.readDisk(standardized) {
                model = TypeScriptAnalysis.parse(source)?.model
            } else {
                model = nil
            }
            if buildingToken != nil {
                pendingEdits[standardized] = model
            }
            if let model {
                files[standardized] = model
            } else {
                files.removeValue(forKey: standardized)
            }
        }
        if buildingToken == nil {
            publish(files)
        }
    }

    func contains(_ url: URL) -> Bool {
        files[url.standardizedFileURL] != nil
    }

    func model(for url: URL) async -> TypeScriptFileModel? {
        if let source = await source(for: url) {
            return TypeScriptAnalysis.parse(source)?.model
        }
        return files[url.standardizedFileURL]
    }

    func source(for url: URL) async -> String? {
        let standardized = url.standardizedFileURL
        if let openBuffer {
            if let text = await openBuffer(standardized) { return text }
            if standardized != url, let text = await openBuffer(url) { return text }
        }
        return files[standardized] == nil ? nil : Self.readDisk(standardized)
    }

    /// Relative specifiers only (`.` or `..`). Matches an indexed file, then an extension, then `index.ts`.
    func resolve(specifier: String, from file: URL) -> URL? {
        guard specifier.hasPrefix(".") else { return nil }
        let base = file.standardizedFileURL.deletingLastPathComponent()
        let raw = base.appendingPathComponent(specifier).standardizedFileURL
        var candidates = [raw]
        if raw.pathExtension.isEmpty {
            for ext in ["ts", "tsx", "mts", "cts"] {
                candidates.append(raw.appendingPathExtension(ext))
                candidates.append(raw.appendingPathComponent("index").appendingPathExtension(ext))
            }
        }
        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            if files[standardized] != nil { return standardized }
        }
        return nil
    }

    /// The declaration exported as `name` from `file`, following `export { X } from` up to four files.
    func resolvedExport(named name: String, in file: URL) async -> (url: URL, declaration: TypeScriptFileModel.Declaration)? {
        await resolvedExport(named: name, in: file.standardizedFileURL, depth: 0, seen: [])
    }

    func exports(matching prefix: String, limit: Int) -> [ExportRef] {
        if prefix.isEmpty {
            var all: [ExportRef] = []
            all.reserveCapacity(min(limit, 128))
            for list in exportsByName.values {
                all.append(contentsOf: list)
                if all.count >= limit { break }
            }
            if all.count > limit { all.removeSubrange(limit...) }
            return all
        }
        var matches: [ExportRef] = []
        for (name, list) in exportsByName where CompletionMatcher.couldMatch(prefix, name) && CompletionMatcher.matches(prefix, name) {
            matches.append(contentsOf: list)
            if matches.count >= 200 { break }
        }
        return matches
    }

    /// Uses of `exportNames` outside `definingFile`: matching imports, and re-exports.
    /// An aliased import contributes the imported-name range only. A same-spelled local is a different binding.
    func externalUses(of exportNames: [String], definingFile: URL) async -> [ExternalUse] {
        let defining = definingFile.standardizedFileURL
        var candidates = Set<URL>()
        for name in exportNames {
            if let files = names[name] {
                candidates.formUnion(files)
            }
        }
        candidates.remove(defining)
        var results: [ExternalUse] = []
        for file in candidates {
            guard let source = await source(for: file), let model = TypeScriptAnalysis.parse(source)?.model else { continue }
            var ranges: [Range<Int>] = []
            for item in model.imports {
                guard exportNames.contains(item.importedName) else { continue }
                guard let resolved = resolve(specifier: item.specifier, from: file), resolved == defining else { continue }
                if item.localName == item.importedName {
                    ranges.append(item.localBytes)
                    if let binding = model.binding(atNameBytes: item.localBytes) {
                        for use in model.uses where use.bindingStart == binding.nameBytes.lowerBound && use.name == binding.name && !use.isMemberProperty {
                            ranges.append(use.bytes)
                        }
                    }
                } else if let imported = item.importedNameBytes {
                    ranges.append(imported)
                }
            }
            for item in model.reexports where exportNames.contains(item.importedName) {
                guard let resolved = resolve(specifier: item.specifier, from: file), resolved == defining else { continue }
                ranges.append(item.nameBytes)
            }
            if !ranges.isEmpty {
                results.append(ExternalUse(url: file, source: source, ranges: ranges))
            }
        }
        return results
    }

    private func resolvedExport(
        named name: String, in file: URL, depth: Int, seen: Set<String>
    ) async -> (url: URL, declaration: TypeScriptFileModel.Declaration)? {
        let file = file.standardizedFileURL
        let key = file.path + "\u{0}" + name
        guard depth < 4, !seen.contains(key) else { return nil }
        guard let model = await model(for: file) else { return nil }
        if let declaration = model.declarations.first(where: { $0.isTopLevel && $0.exportNames.contains(name) }) {
            return (file, declaration)
        }
        if let reexport = model.reexports.first(where: { $0.exportedName == name }),
           let next = resolve(specifier: reexport.specifier, from: file) {
            var seen = seen
            seen.insert(key)
            return await resolvedExport(named: reexport.importedName, in: next, depth: depth + 1, seen: seen)
        }
        return nil
    }

    private func parseAll(_ urls: [URL]) async -> [URL: TypeScriptFileModel] {
        let limit = 8
        return await withTaskGroup(of: (URL, TypeScriptFileModel)?.self) { group in
            var next = 0
            func add(_ url: URL) {
                group.addTask {
                    if Task.isCancelled { return nil }
                    guard let source = TypeScriptIndex.readDisk(url) else { return nil }
                    guard let model = TypeScriptAnalysis.parse(source)?.model else { return nil }
                    return (url, model)
                }
            }
            while next < urls.count && next < limit {
                add(urls[next])
                next += 1
            }
            var result: [URL: TypeScriptFileModel] = [:]
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

    /// Types and members whose names match `query`, in index order, up to `limit`. An empty query matches nothing.
    func symbols(matching query: String, limit: Int) -> [PaletteSymbol] {
        guard limit > 0, !query.isEmpty else { return [] }
        var matches: [PaletteSymbol] = []
        matches.reserveCapacity(min(limit, 32))
        for symbol in paletteSymbols {
            guard CompletionMatcher.couldMatch(query, symbol.name),
                  CompletionMatcher.matches(query, symbol.name) else { continue }
            matches.append(symbol)
            if matches.count == limit { break }
        }
        return matches
    }

    private func publish(_ models: [URL: TypeScriptFileModel]) {
        files = models
        var names: [String: Set<URL>] = [:]
        var exports: [String: [ExportRef]] = [:]
        var symbols: [PaletteSymbol] = []
        for (url, model) in models {
            collectPaletteSymbols(model.declarations, container: "", url: url, into: &symbols)
            for name in model.identifiers {
                names[name, default: []].insert(url)
            }
            for declaration in model.declarations where declaration.isTopLevel {
                let typeOnly = declaration.kind == .interface || declaration.kind == .typeAlias
                for name in declaration.exportNames where name != "default" {
                    exports[name, default: []].append(ExportRef(
                        name: name, url: url, kind: declaration.kind, signature: declaration.signature, isTypeOnly: typeOnly
                    ))
                }
            }
            for reexport in model.reexports where reexport.exportedName != "default" {
                exports[reexport.exportedName, default: []].append(ExportRef(
                    name: reexport.exportedName, url: url, kind: .variable, signature: reexport.exportedName, isTypeOnly: false
                ))
            }
        }
        self.names = names
        exportsByName = exports
        paletteSymbols = symbols
    }

    private func collectPaletteSymbols(
        _ declarations: [TypeScriptFileModel.Declaration], container: String, url: URL,
        into symbols: inout [PaletteSymbol]
    ) {
        for declaration in declarations {
            let include = declaration.kind.isType
                || declaration.kind == .method || declaration.kind == .field || declaration.kind == .enumMember
            if include {
                symbols.append(PaletteSymbol(
                    name: declaration.name, container: container, url: url,
                    kind: declaration.kind, nameBytes: declaration.nameBytes
                ))
            }
            let next = declaration.kind.isType ? declaration.name : container
            if !declaration.members.isEmpty {
                collectPaletteSymbols(declaration.members, container: next, url: url, into: &symbols)
            }
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
                if TypeScriptPaths.skipDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard TypeScriptPaths.isSourceFile(url), !TypeScriptPaths.isSkipped(url) else { continue }
            if let size = values?.fileSize, size > TypeScriptPaths.maxBytes { continue }
            urls.append(url.standardizedFileURL)
        }
        return urls
    }

    private static func readDisk(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        guard data.count <= TypeScriptPaths.maxBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
