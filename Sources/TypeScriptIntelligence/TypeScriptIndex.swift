import EditorIntelligence
import Foundation

/// Project TypeScript files, indexed off the keystroke path. A query reads the open buffer when
/// the host has one and the indexed tree otherwise. Package names and `node_modules` are not resolved.
public actor TypeScriptIndex {
    public init() {}
    public struct ExportRef: Sendable {
        public var name: String
        public var url: URL
        public var kind: TypeScriptFileModel.Kind
        public var signature: String
        public var isTypeOnly: Bool
    }

    public struct ExternalUse: Sendable {
        public var url: URL
        public var source: String
        public var ranges: [Range<Int>]
    }

    private var storage = SourceFileIndex<TypeScriptFileModel>(configuration: .typeScriptFiles)
    public struct PaletteSymbol: Sendable, Equatable {
        public var name: String
        public var container: String
        public var url: URL
        public var kind: TypeScriptFileModel.Kind
        public var nameBytes: Range<Int>
    }

    private var names: [String: Set<URL>] = [:]
    private var exportsByName: [String: [ExportRef]] = [:]
    private var paletteSymbols: [PaletteSymbol] = []
    public func setOpenBufferLookup(_ lookup: (@Sendable (URL) async -> String?)?) {
        storage.setOpenBufferLookup(lookup)
    }

    public var fileCount: Int { storage.fileCount }

    /// Rebuilds the index for `root` (or clears it). A newer call wins; a cancelled one does not publish.
    public func setRoot(_ root: URL?) async {
        if Task.isCancelled { return }
        let walk = storage.beginWalk(root: root)
        guard let standardized = walk.root else {
            publish([:])
            storage.finishWalk(walk.token)
            return
        }
        let configuration = storage.configuration
        let urls = await Task.detached {
            SourceFileIndex<TypeScriptFileModel>.enumerate(root: standardized, configuration: configuration)
        }.value
        guard storage.isCurrent(walk.token), !Task.isCancelled else {
            storage.cancelWalk(walk.token)
            return
        }
        let parsed = await SourceFileIndex<TypeScriptFileModel>.parseAll(urls, configuration: configuration)
        guard storage.isCurrent(walk.token), !Task.isCancelled else {
            storage.cancelWalk(walk.token)
            return
        }
        let merged = storage.mergingPending(into: parsed)
        publish(merged)
        storage.finishWalk(walk.token)
    }

    public func applyFileChanges(_ urls: [URL]) async {
        for url in urls {
            let standardized = url.standardizedFileURL
            guard TypeScriptPaths.isSourceFile(standardized), !TypeScriptPaths.isSkipped(standardized) else { continue }
            let model: TypeScriptFileModel?
            if FileManager.default.fileExists(atPath: standardized.path),
               let source = SourceFileIndex<TypeScriptFileModel>.readDisk(standardized, maxBytes: storage.configuration.maxBytes) {
                model = storage.parse(source, url: standardized)
            } else {
                model = nil
            }
            storage.recordPending(standardized, model)
            if let model {
                storage.insert(standardized, model)
            } else {
                _ = storage.remove(standardized)
            }
        }
        if !storage.isBuilding {
            publish(storage.storedFiles)
        }
    }

    public func contains(_ url: URL) -> Bool {
        storage.contains(url)
    }

    public func model(for url: URL) async -> TypeScriptFileModel? {
        if let source = await source(for: url) {
            return TypeScriptAnalysis.parse(source, fileURL: url)?.model
        }
        return storage.file(at: url)
    }

    /// The text the editor shows for `url`, else the file on disk when it is indexed.
    /// The open buffer is tried at the standardized URL, then at `url` itself.
    public func source(for url: URL) async -> String? {
        let standardized = url.standardizedFileURL
        if let openBuffer = storage.openBuffer {
            if let text = await openBuffer(standardized) { return text }
            if standardized != url, let text = await openBuffer(url) { return text }
        }
        guard storage.contains(standardized) else { return nil }
        return SourceFileIndex<TypeScriptFileModel>.readDisk(standardized, maxBytes: storage.configuration.maxBytes)
    }

    /// Relative specifiers only (`.` or `..`). Matches an indexed file, then an extension, then `index.ts`.
    public func resolve(specifier: String, from file: URL) -> URL? {
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
            if storage.contains(standardized) { return standardized }
        }
        return nil
    }

    /// The declaration exported as `name` from `file`, following `export { X } from` up to four files.
    public func resolvedExport(named name: String, in file: URL) async -> (url: URL, declaration: TypeScriptFileModel.Declaration)? {
        await resolvedExport(named: name, in: file.standardizedFileURL, depth: 0, seen: [])
    }

    public func exports(matching prefix: String, limit: Int) -> [ExportRef] {
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
    public func externalUses(of exportNames: [String], definingFile: URL) async -> [ExternalUse] {
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
            guard let source = await source(for: file), let model = TypeScriptAnalysis.parse(source, fileURL: file)?.model else { continue }
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

    /// Types and members whose names match `query`, in index order, up to `limit`. An empty query matches nothing.
    public func symbols(matching query: String, limit: Int) -> [PaletteSymbol] {
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
        storage.replaceFiles(with: models)
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

}

private extension SourceFileIndex.Configuration where Model == TypeScriptFileModel {
    static var typeScriptFiles: Self {
        Self(
            skipDirectories: TypeScriptPaths.skipDirectories,
            maxBytes: TypeScriptPaths.maxBytes,
            isSourceFile: { TypeScriptPaths.isSourceFile($0) },
            isSkipped: { TypeScriptPaths.isSkipped($0) },
            parse: { source, url in TypeScriptAnalysis.parse(source, fileURL: url)?.model }
        )
    }
}
