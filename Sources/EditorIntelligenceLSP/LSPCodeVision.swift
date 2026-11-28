import EditorIntelligence
import Foundation
import LanguageServerProtocol

/// A language server's code lenses as code vision.
///
/// `textDocument/codeLens` gives the lenses; the title of each lens's command is the label. A lens that
/// arrives without its command is resolved (`codeLens/resolve`) when it is on screen, a few at a time.
/// A click runs the command only when the editor can: `showReferences` goes to the editor's own
/// references, and a command the server declared runs on the server. Anything else is left alone.
struct LSPReadyCodeVision: CodeVisionProviding {
    let languages: Set<String>
    let connections: any LSPConnectionProviding
    private let store = LSPCodeLensStore()

    /// Most lenses given room in one file.
    static let maximumAnchors = 400
    /// Most lenses resolved in one request. Each is a round trip.
    static let maximumResolves = 16
    static let maximumTitleLength = 120

    init(languages: Set<String>, connections: any LSPConnectionProviding) {
        self.languages = languages
        self.connections = connections
    }

    func codeVisionAnchors(for document: Document) async -> [Int] {
        guard let client = client(for: document) else { return [] }
        return await load(document, client: client).keys.sorted()
    }

    func codeVision(for document: Document, anchors: [Int]) async -> [CodeVisionLens] {
        guard let client = client(for: document), let key = Self.key(of: document) else { return [] }
        var loaded = await store.lenses(for: key, version: document.contentSnapshot.version)
        if loaded == nil { loaded = await load(document, client: client) }
        guard var lenses = loaded else { return [] }
        var resolves = 0
        var result: [CodeVisionLens] = []
        for anchor in Set(anchors).sorted() {
            guard !Task.isCancelled else { return [] }
            var entries: [CodeVisionEntry] = []
            for (position, lens) in (lenses[anchor] ?? []).enumerated() {
                var current = lens
                if current.command == nil, resolves < Self.maximumResolves {
                    resolves += 1
                    if let resolved = try? await client.resolveCodeLens(current) {
                        current = resolved
                        lenses[anchor]?[position] = resolved
                    }
                }
                guard let command = current.command, let title = Self.title(of: command) else { continue }
                let id = await store.register(command)
                entries.append(CodeVisionEntry(id: id, text: title))
            }
            result.append(CodeVisionLens(utf16Offset: anchor, entries: entries))
        }
        guard !Task.isCancelled else { return [] }
        await store.update(lenses, for: key, version: document.contentSnapshot.version)
        return result
    }

    func activateCodeVisionEntry(_ entry: CodeVisionEntry, atAnchor anchor: Int, in document: Document) async -> CodeVisionActivation {
        guard let command = await store.command(forEntry: entry.id), let client = client(for: document) else { return .unhandled }
        let name = command.command.lowercased()
        // The positions in the arguments belong to the text the lenses were requested for.
        let fresh = await store.isCurrent(Self.key(of: document), version: document.contentSnapshot.version)
        let offset = fresh ? Self.symbolOffset(in: command, document: document) ?? anchor : anchor
        if name.hasSuffix("showreferences") { return .showReferences(offset: offset) }
        if name.hasSuffix("showimplementations") || name.hasSuffix("gotoimplementation") { return .showImplementations(offset: offset) }
        return await client.executeCodeLensCommand(command) ? .handled : .unhandled
    }

    // MARK: - Loading

    private func client(for document: Document) -> LanguageServerClient? {
        lspClient(connections, feature: .codeVision, languages: languages, documentLanguage: document.languageIdentifier) as? LanguageServerClient
    }

    private static func key(of document: Document) -> String? {
        document.url?.absoluteString
    }

    /// Requests the lenses and groups them by the line they sit above (the start of the lens's range).
    private func load(_ document: Document, client: LanguageServerClient) async -> [Int: [LanguageServerProtocol.CodeLens]] {
        guard let key = Self.key(of: document),
              let lenses = try? await client.requestCodeLenses(for: document), !Task.isCancelled else { return [:] }
        let map = SourceTextMap(documentText(document))
        var byAnchor: [Int: [LanguageServerProtocol.CodeLens]] = [:]
        for lens in lenses {
            guard let offset = map.utf16Offset(line: lens.range.start.line, column: lens.range.start.character),
                  byAnchor.count < Self.maximumAnchors || byAnchor[offset] != nil else { continue }
            byAnchor[offset, default: []].append(lens)
        }
        await store.update(byAnchor, for: key, version: document.contentSnapshot.version)
        return byAnchor
    }

    /// A single-line label for a command: its title, trimmed and bounded. Nil for an empty title.
    static func title(of command: Command) -> String? {
        let line = command.title.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumTitleLength))
    }

    /// `showReferences` carries the symbol's position as its second argument: `[uri, {line, character}, locations]`.
    private static func symbolOffset(in command: Command, document: Document) -> Int? {
        guard let arguments = command.arguments, arguments.count >= 2,
              let data = try? JSONEncoder().encode(arguments[1]),
              let position = try? JSONDecoder().decode(LanguageServerProtocol.Position.self, from: data) else { return nil }
        return SourceTextMap(documentText(document)).utf16Offset(line: position.line, column: position.character)
    }
}

/// The lenses last read for each document, and the commands behind the entries shown for them.
actor LSPCodeLensStore {
    private struct Snapshot {
        var version: Int
        var lenses: [Int: [LanguageServerProtocol.CodeLens]]
    }

    private var snapshots: [String: Snapshot] = [:]
    private var commands: [String: Command] = [:]
    private var order: [String] = []
    private var counter = 0
    private static let maximumCommands = 2000
    private static let maximumDocuments = 64

    func lenses(for key: String, version: Int) -> [Int: [LanguageServerProtocol.CodeLens]]? {
        guard let snapshot = snapshots[key], snapshot.version == version else { return nil }
        return snapshot.lenses
    }

    func update(_ lenses: [Int: [LanguageServerProtocol.CodeLens]], for key: String, version: Int) {
        if snapshots.count >= Self.maximumDocuments, snapshots[key] == nil { snapshots.removeAll() }
        snapshots[key] = Snapshot(version: version, lenses: lenses)
    }

    func isCurrent(_ key: String?, version: Int) -> Bool {
        guard let key else { return false }
        return snapshots[key]?.version == version
    }

    /// An id for a click on `command`'s entry to find it again by.
    func register(_ command: Command) -> String {
        counter += 1
        let id = "lsp:\(counter)"
        commands[id] = command
        order.append(id)
        if order.count > Self.maximumCommands {
            for old in order.prefix(order.count - Self.maximumCommands) { commands[old] = nil }
            order.removeFirst(order.count - Self.maximumCommands)
        }
        return id
    }

    func command(forEntry id: String) -> Command? {
        commands[id]
    }
}
