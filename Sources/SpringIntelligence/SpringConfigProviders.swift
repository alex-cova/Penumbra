import EditorIntelligence
import Foundation

extension SpringTextRanges {
    /// Positions for UTF-16 offsets (what the editor's cursor and completion ranges use).
    func rangeUTF16(_ lower: Int, _ upper: Int, in text: String) -> EditorIntelligence.TextRange {
        let ns = text as NSString
        let a = ns.substring(to: min(lower, ns.length)).utf8.count
        let b = ns.substring(to: min(upper, ns.length)).utf8.count
        return range(a..<b)
    }
}

/// Shared plumbing: is this document an `application*` file the Spring model owns, and what does it say?
struct SpringConfigContext {
    let url: URL
    let text: String
    let config: SpringConfigModel

    init?(document: Document, indexer: SpringWorkspaceIndexer) async {
        guard let url = document.url?.standardizedFileURL, url.pathExtension != "java",
              await indexer.containsConfig(url) else { return nil }
        self.url = url
        text = document.text
        await indexer.ingest(url: url, text: text)
        config = await indexer.store.config()
    }

    func byte(utf16: Int) -> Int { SpringNavigationProvider.byteOffset(utf16: utf16, in: text) }
}

// MARK: - Diagnostics

public struct SpringConfigDiagnosticProvider: DiagnosticProvider {
    public let name = "spring-config"
    private let indexer: SpringWorkspaceIndexer
    public init(indexer: SpringWorkspaceIndexer) { self.indexer = indexer }

    public func diagnostics(for document: Document) async -> [Diagnostic] {
        guard let ctx = await SpringConfigContext(document: document, indexer: indexer), !Task.isCancelled else { return [] }
        let found = ctx.config.diagnostics(for: ctx.url)
        guard !found.isEmpty else { return [] }
        let ranges = SpringTextRanges(text: ctx.text)
        return found.map {
            Diagnostic(
                severity: { switch $0.severity { case .error: .error; case .warning: .warning; case .info: .information } }($0),
                message: $0.message, range: ranges.range($0.location.byteRange), source: "Spring", code: $0.code)
        }
    }
}

// MARK: - Hover

public struct SpringConfigHoverProvider: HoverProvider {
    public let name = "spring-config"
    private let indexer: SpringWorkspaceIndexer
    public init(indexer: SpringWorkspaceIndexer) { self.indexer = indexer }

    public func provide(context: HoverContext) async -> HoverResult? {
        guard let ctx = await SpringConfigContext(document: context.document, indexer: indexer),
              let (file, hit) = ctx.config.hit(in: ctx.url, atByte: ctx.byte(utf16: context.cursor.position.utf16Offset)) else { return nil }
        let entry: SpringConfigEntry, key: String, span: Range<Int>
        switch hit {
        case .key(let e, let segment):
            entry = e
            key = e.segments.prefix(segment + 1).map(\.name).joined(separator: ".")
            span = e.segments[segment].range
        case .value(let e):
            entry = e; key = e.key; span = e.valueRange ?? e.keyRange
        }
        let isFullKey = key == entry.key
        let ranges = SpringTextRanges(text: ctx.text)
        let md = Self.markdown(key: key, entry: entry, file: file, isFullKey: isFullKey, config: ctx.config)
        return HoverResult(contents: md, range: ranges.range(span), source: "Spring")
    }

    static func markdown(key: String, entry: SpringConfigEntry, file: SpringConfigFile, isFullKey: Bool, config: SpringConfigModel) -> String {
        var lines: [String] = []
        switch config.metadata.match(key) {
        case .exact(let p):
            lines.append("**`\(p.name)`**" + (p.type.map { " — `\($0)`" } ?? ""))
            if let d = p.description { lines.append(d) }
            if let d = p.defaultValue { lines.append("Default: `\(d)`") }
            if let dep = p.deprecation {
                lines.append("**Deprecated**" + (dep.reason.map { ": \($0)" } ?? "") + (dep.replacement.map { " Replacement: `\($0)`." } ?? ""))
            }
            switch p.origin {
            case .metadata(let from): lines.append("Metadata: \(from)")
            case .source(_, let cls): lines.append("Bound by `\(cls)`")
            }
        case .opaque(let parent):
            lines.append("**`\(key)`** — an entry under `\(parent.name)`" + (parent.type.map { " (`\($0)`)" } ?? ""))
            if let d = parent.description { lines.append(d) }
        case .group:
            lines.append("**`\(key)`** — a group of properties")
        case .unknown:
            lines.append("**`\(key)`** — not a known property" + (config.suggestion(for: key).map { ". Did you mean `\($0)`?" } ?? ""))
        case .foreign:
            lines.append("**`\(key)`** — no metadata available (a library without configuration metadata, or a custom key)")
        }
        guard isFullKey else { return lines.joined(separator: "\n\n") }
        let place = "\(file.url.lastPathComponent):\(entry.line + 1)" + (file.profile(of: entry).map { " (profile `\($0)`)" } ?? "")
        if let eff = config.effective(key: entry.key) {
            let winnerPlace = "\(eff.winner.file.url.lastPathComponent):\(eff.winner.entry.line + 1)"
            let value = eff.winner.entry.value.map { "`\($0)`" } ?? "empty"
            if eff.winner.entry == entry, eff.winner.file.url == file.url {
                lines.append("Effective value: \(value) — set here (\(place))")
            } else {
                lines.append("Set here (\(place)); effective value is \(value) from \(winnerPlace)")
            }
            if !eff.inactive.isEmpty {
                lines.append("Also set under inactive profiles: " + eff.inactive.map { "`\($0.profile ?? "?")`" }.joined(separator: ", "))
            }
            lines.append(config.profilesAssumed
                ? "_Active profiles are unknown here; profile-specific files may change this._"
                : "_Active profiles: \(config.activeProfiles.isEmpty ? "none" : config.activeProfiles.joined(separator: ", "))._")
        }
        lines.append("_Environment variables, system properties and command-line arguments override file values and cannot be seen here._")
        return lines.joined(separator: "\n\n")
    }
}

// MARK: - Completion

public struct SpringConfigCompletionProvider: CompletionProvider {
    public let name = "spring-config"
    private let indexer: SpringWorkspaceIndexer
    public init(indexer: SpringWorkspaceIndexer) { self.indexer = indexer }

    public func isPrimary(for context: CompletionContext) -> Bool { false }

    public func provide(context: CompletionContext) async -> [CompletionItem] {
        guard let ctx = await SpringConfigContext(document: context.document, indexer: indexer), !Task.isCancelled else { return [] }
        let ns = ctx.text as NSString
        let caret = min(context.cursor.position.utf16Offset, ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        let before = ns.substring(with: NSRange(location: lineRange.location, length: caret - lineRange.location))
        let isYAML = ctx.url.pathExtension.lowercased() != "properties"
        let ranges = SpringTextRanges(text: ctx.text)
        let site = Self.site(lineBefore: before, isYAML: isYAML, textBeforeLine: ns.substring(to: lineRange.location))
        let file = ctx.config.file(at: ctx.url)
        switch site {
        case .none:
            return []
        case .placeholder(let typedStart):
            let typed = String(before.dropFirst(typedStart)).trimmingCharacters(in: .whitespaces)
            let from = lineRange.location + (before as NSString).length - (String(before.dropFirst(typedStart)) as NSString).length
            let r = ranges.rangeUTF16(from, caret, in: ctx.text)
            var keys: [String: String?] = [:]
            for f in ctx.config.files { for e in f.entries { keys[e.key] = e.value } }
            for p in ctx.config.metadata.properties.values { if keys[p.name] == nil { keys[p.name] = p.defaultValue } }
            return keys.keys.sorted().filter { typed.isEmpty || SpringConfigMetadata.uniform($0).contains(SpringConfigMetadata.uniform(typed)) }.prefix(200).map {
                CompletionItem(label: $0, insertText: $0, kind: .property, range: r, source: "Spring", detail: keys[$0] ?? nil)
            }
        case .value(let key, let typedStart):
            let typed = String(before.dropFirst(typedStart))
            let from = caret - (typed as NSString).length
            let r = ranges.rangeUTF16(from, caret, in: ctx.text)
            return Self.valueItems(key: key, typed: typed, range: r, config: ctx.config)
        case .key(let parentPath, let typedStart):
            let typed = String(before.dropFirst(typedStart))
            let from = caret - (typed as NSString).length
            let r = ranges.rangeUTF16(from, caret, in: ctx.text)
            let defined = Set((file?.entries ?? []).map { SpringConfigMetadata.uniform($0.key) })
            return Self.keyItems(parent: parentPath, typed: typed, range: r, isYAML: isYAML, config: ctx.config,
                                 defined: defined, fileProfile: file?.fileProfile)
        }
    }

    enum Site: Equatable {
        case none
        case key(parent: String, typedStart: Int)
        case value(key: String, typedStart: Int)
        case placeholder(typedStart: Int)
    }

    /// Where the caret is in an application file, from the text of its line and (for YAML) the lines above.
    static func site(lineBefore: String, isYAML: Bool, textBeforeLine: String) -> Site {
        let chars = Array(lineBefore)
        // Inside an unclosed `${` of a value.
        if let open = lineBefore.range(of: "${", options: .backwards), !lineBefore[open.upperBound...].contains("}"),
           !lineBefore[open.upperBound...].contains(":") {
            return .placeholder(typedStart: lineBefore.distance(from: lineBefore.startIndex, to: open.upperBound))
        }
        if lineBefore.trimmingCharacters(in: .whitespaces).hasPrefix("#") || lineBefore.trimmingCharacters(in: .whitespaces).hasPrefix("!") { return .none }
        if isYAML {
            var indent = 0
            while indent < chars.count, chars[indent] == " " { indent += 1 }
            var start = indent
            if lineBefore.dropFirst(indent).hasPrefix("- ") { start = indent + 2 }
            let rest = String(chars[start...])
            if let colon = rest.range(of: ": ") ?? (rest.hasSuffix(":") ? rest.range(of: ":", options: .backwards) : nil) {
                let keyText = String(rest[..<colon.lowerBound])
                let parent = yamlParent(before: textBeforeLine, indent: indent)
                let key = parent.isEmpty ? keyText : parent + "." + keyText
                let valueStart = start + rest.distance(from: rest.startIndex, to: colon.upperBound)
                return .value(key: key, typedStart: min(valueStart, chars.count))
            }
            if rest.contains(":") { return .none }
            return .key(parent: yamlParent(before: textBeforeLine, indent: indent), typedStart: start)
        }
        var i = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        let keyStart = i
        while i < chars.count, chars[i] != "=", chars[i] != ":", chars[i] != " " { i += 1 }
        if i >= chars.count { return .key(parent: "", typedStart: keyStart) }
        let key = String(chars[keyStart..<i])
        var v = i
        while v < chars.count, chars[v] == " " || chars[v] == "=" || chars[v] == ":" { v += 1 }
        return .value(key: key, typedStart: v)
    }

    /// The dotted path of the YAML mapping a new key at `indent` belongs to, from the lines above it.
    static func yamlParent(before text: String, indent: Int) -> String {
        var stack: [(indent: Int, key: String)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let body = raw.drop(while: { $0 == " " })
            let ind = raw.count - body.count
            if body.isEmpty || body.first == "#" || body.hasPrefix("-") || body.hasPrefix("---") { continue }
            while let top = stack.last, top.indent >= ind { stack.removeLast() }
            guard let colon = body.firstIndex(of: ":") else { continue }
            let after = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if after.isEmpty || after.hasPrefix("#") { stack.append((ind, String(body[..<colon]))) }
        }
        while let top = stack.last, top.indent >= indent { stack.removeLast() }
        return stack.map(\.key).joined(separator: ".")
    }

    static func keyItems(
        parent: String, typed: String, range: EditorIntelligence.TextRange, isYAML: Bool, config: SpringConfigModel,
        defined: Set<String>, fileProfile: String?
    ) -> [CompletionItem] {
        let full = parent.isEmpty ? typed : parent + "." + typed
        let uniformPrefix = SpringConfigMetadata.uniform(full)
        var items: [CompletionItem] = []
        var seen = Set<String>()
        for p in config.metadata.names(withUniformPrefix: uniformPrefix, limit: 600) {
            let rel = parent.isEmpty ? p.name : String(p.name.dropFirst(parent.count + 1))
            // YAML nests one level at a time unless the user is already typing a dotted key.
            let parts = rel.split(separator: ".").map(String.init)
            let label: String
            let isLeaf: Bool
            if isYAML, !typed.contains("."), parts.count > 1 { label = parts[0]; isLeaf = false } else { label = rel; isLeaf = true }
            guard seen.insert(label).inserted else { continue }
            if isLeaf, defined.contains(SpringConfigMetadata.uniform(p.name)) { continue }
            let insert: String = isYAML ? (isLeaf ? label + ": " : label + ":") : label + "="
            // In a profile file, keys already set in base configuration are the likely overrides.
            let overrides = fileProfile != nil && config.definesKey(p.name)
            items.append(CompletionItem(
                label: label, insertText: insert, kind: isLeaf ? .property : .module, range: range, source: "Spring",
                documentation: p.description, detail: isLeaf ? p.type.map(shortType) : "group",
                labelDetail: p.defaultValue.map { " = \($0)" }, isDeprecated: p.deprecation != nil,
                priority: overrides ? 0.3 : (p.deprecation != nil ? -0.5 : 0)))
        }
        // Deprecated keys name their replacement.
        return items.map { item in
            guard let p = config.metadata.properties[SpringConfigMetadata.uniform(parent.isEmpty ? item.label : parent + "." + item.label)],
                  let r = p.deprecation?.replacement else { return item }
            return CompletionItem(id: item.id, label: item.label, insertText: item.insertText, kind: item.kind, range: item.range,
                                  source: item.source, documentation: item.documentation, detail: "deprecated → \(r)",
                                  labelDetail: item.labelDetail, isDeprecated: true, priority: item.priority)
        }
    }

    static func valueItems(key: String, typed: String, range: EditorIntelligence.TextRange, config: SpringConfigModel) -> [CompletionItem] {
        let u = SpringConfigMetadata.uniform(SpringConfigMetadata.stripIndexes(key))
        var values: [(String, String?)] = []
        if ["spring.profiles.active", "spring.profiles.include", "spring.config.activate.on-profile"].contains(key) {
            values = config.knownProfiles.sorted().map { ($0, "profile") }
        }
        if let hints = config.metadata.hints[u] { values += hints.map { ($0.value, $0.description) } }
        if let p = config.metadata.properties[u] {
            if p.type == "java.lang.Boolean" || p.type == "boolean", !values.contains(where: { $0.0 == "true" }) { values += [("true", nil), ("false", nil)] }
            if let d = p.defaultValue, !values.contains(where: { $0.0 == d }) { values.append((d, "default")) }
        }
        return values.filter { typed.isEmpty || $0.0.lowercased().hasPrefix(typed.lowercased()) }.map {
            CompletionItem(label: $0.0, insertText: $0.0, kind: .enumMember, range: range, source: "Spring", detail: $0.1)
        }
    }

    private static func shortType(_ t: String) -> String {
        t.replacingOccurrences(of: "java.lang.", with: "").replacingOccurrences(of: "java.util.", with: "").replacingOccurrences(of: "java.time.", with: "")
    }
}

// MARK: - Navigation

/// Between configuration keys and the Java that reads them, both directions. From an `application*` key: the
/// `@ConfigurationProperties` field that binds it and every `@Value` that mentions it. From Java: a
/// `@Value("${key}")` placeholder or a `@ConfigurationProperties` prefix to the file entries that set it.
public struct SpringConfigNavigationProvider: NavigationProvider {
    public let name = "spring-config-navigation"
    private let indexer: SpringWorkspaceIndexer
    public init(indexer: SpringWorkspaceIndexer) { self.indexer = indexer }

    public func isPrimary(for context: NavigationContext) -> Bool {
        context.document.languageIdentifier == "java" && context.document.url != nil
    }

    public func provide(context: NavigationContext) async -> NavigationResult? {
        guard context.kind == .definition || context.kind == .implementation else { return nil }
        let doc = context.document
        if doc.languageIdentifier == "java" { return await fromJava(context) }
        guard let ctx = await SpringConfigContext(document: doc, indexer: indexer),
              let (file, hit) = ctx.config.hit(in: ctx.url, atByte: ctx.byte(utf16: context.cursor.position.utf16Offset)) else { return nil }
        let model = await indexer.store.model()
        var targets: [(URL, Range<Int>, String)] = []
        switch hit {
        case .key(let e, let segment):
            // The segment under the caret names a group (`app.mail`) or the whole key.
            let partial = e.segments.prefix(segment + 1).map(\.name).joined(separator: ".")
            targets += Self.javaTargets(forKey: partial, config: ctx.config, model: model)
        case .value(let e):
            if e.key == "spring.config.import", let v = e.value {
                for item in v.split(separator: ",") {
                    if let u = ctx.config.resolveImport(item.trimmingCharacters(in: .whitespaces), from: file.url),
                       FileManager.default.fileExists(atPath: u.path) { targets.append((u, 0..<0, u.lastPathComponent)) }
                }
            }
            if let v = e.value, let r = e.valueRange {
                // A `${key}` placeholder under the caret leads to where that key is set.
                let caretInValue = ctx.byte(utf16: context.cursor.position.utf16Offset) - r.lowerBound
                for p in SpringPlaceholder.scan(v) {
                    let lo = String(v.utf16.prefix(p.keyRange.lowerBound))!.utf8.count, hi = String(v.utf16.prefix(p.keyRange.upperBound))!.utf8.count
                    if caretInValue >= lo, caretInValue <= hi {
                        for (f, entry) in ctx.config.entries(forKey: p.key) { targets.append((f.url, entry.keyRange, "\(p.key) — \(f.url.lastPathComponent)")) }
                    }
                }
            }
        }
        return Self.result(targets, current: doc, currentText: ctx.text)
    }

    private func fromJava(_ context: NavigationContext) async -> NavigationResult? {
        let doc = context.document
        guard let url = doc.url?.standardizedFileURL, await indexer.contains(url) else { return nil }
        let text = doc.text
        let caret = context.cursor.position.utf16Offset
        guard let hit = Self.javaSite(text: text, caretUTF16: caret) else { return nil }
        await indexer.ingest(url: url, text: text)
        let config = await indexer.store.config()
        var targets: [(URL, Range<Int>, String)] = []
        switch hit {
        case .placeholder(let key):
            for (f, e) in config.entries(forKey: key) { targets.append((f.url, e.keyRange, "\(e.key) — \(f.url.lastPathComponent)\(f.profile(of: e).map { " (\($0))" } ?? "")")) }
        case .prefix(let prefix):
            for (f, e) in config.entries(underPrefix: prefix) { targets.append((f.url, e.keyRange, "\(e.key) — \(f.url.lastPathComponent)")) }
        }
        return Self.result(targets, current: doc, currentText: text)
    }

    enum JavaSite: Equatable { case placeholder(String), prefix(String) }

    /// `@Value("…${key}…")` or `@ConfigurationProperties("prefix")` with the caret inside the string.
    static func javaSite(text: String, caretUTF16: Int) -> JavaSite? {
        let ns = text as NSString
        guard caretUTF16 <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: caretUTF16, length: 0))
        let lineText = ns.substring(with: line)
        let caretInLine = caretUTF16 - line.location
        guard let valueRegex = try? NSRegularExpression(pattern: #"@(?:[A-Za-z_]\w*\.)*(Value|ConfigurationProperties|RequestMapping|GetMapping|PostMapping|PutMapping|PatchMapping|DeleteMapping)\s*\(\s*(?:(?:value|prefix|path)\s*=\s*)?"((?:[^"\\]|\\.)*)""#) else { return nil }
        for m in valueRegex.matches(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) {
            let content = m.range(at: 2)
            guard caretInLine >= content.location, caretInLine <= content.location + content.length else { continue }
            let string = (lineText as NSString).substring(with: content)
            let kind = (lineText as NSString).substring(with: m.range(at: 1))
            if kind == "ConfigurationProperties" { return .prefix(string) }
            let offset = caretInLine - content.location
            for p in SpringPlaceholder.scan(string) where offset >= p.keyRange.lowerBound && offset <= p.keyRange.upperBound { return .placeholder(p.key) }
        }
        return nil
    }

    static func javaTargets(forKey key: String, config: SpringConfigModel, model: SpringModel) -> [(URL, Range<Int>, String)] {
        var out: [(URL, Range<Int>, String)] = []
        if case .exact(let p) = config.metadata.match(key), case .source(let loc, let cls) = p.origin {
            out.append((loc.url, loc.byteRange, "\(p.name) — \(cls)"))
        }
        let u = SpringConfigMetadata.uniform(SpringConfigMetadata.stripIndexes(key))
        for ref in model.valueReferences where SpringConfigMetadata.uniform(ref.key) == u {
            out.append((ref.location.url, ref.location.byteRange, "@Value(\"${\(ref.key)}\") — \(ref.location.url.lastPathComponent)"))
        }
        for pre in model.configurationPrefixes where SpringConfigMetadata.uniform(pre.prefix) == u {
            out.append((pre.location.url, pre.location.byteRange, "@ConfigurationProperties(\"\(pre.prefix)\") — \(pre.typeName)"))
        }
        return out
    }

    static func result(_ targets: [(URL, Range<Int>, String)], current: Document, currentText: String) -> NavigationResult? {
        var cache: [URL: SpringTextRanges] = [:]
        if let u = current.url?.standardizedFileURL { cache[u] = SpringTextRanges(text: currentText) }
        var seen = Set<String>()
        let locations: [Location] = targets.compactMap { (url, range, title) in
            guard seen.insert("\(url.path):\(range.lowerBound)").inserted else { return nil }
            if cache[url] == nil, let t = try? String(contentsOf: url, encoding: .utf8) { cache[url] = SpringTextRanges(text: t) }
            guard let ranges = cache[url] else { return nil }
            return Location(documentID: url == current.url?.standardizedFileURL ? current.id : DocumentID(), url: url,
                            range: ranges.range(range), displayName: title)
        }
        switch locations.count {
        case 0: return nil
        case 1: return .single(locations[0])
        default: return .multiple(locations)
        }
    }
}

// MARK: - Quick fixes

/// Replace a deprecated key with its replacement, or a misspelt one with the closest known key. Single-line
/// keys only (a nested YAML key cannot be renamed by editing one line without restructuring the file).
public struct SpringConfigCodeActionProvider: CodeActionProviding {
    private let indexer: SpringWorkspaceIndexer
    public init(indexer: SpringWorkspaceIndexer) { self.indexer = indexer }

    public func codeActions(for document: Document, at position: TextPosition, diagnostics: [Diagnostic]) async -> [CodeAction] {
        guard let ctx = await SpringConfigContext(document: document, indexer: indexer),
              let (file, hit) = ctx.config.hit(in: ctx.url, atByte: ctx.byte(utf16: position.utf16Offset)),
              case .key(let entry, _) = hit else { return [] }
        let ranges = SpringTextRanges(text: ctx.text)
        let written = String(decoding: Array(ctx.text.utf8)[entry.keyRange], as: UTF8.self)
        guard written == entry.key else { return [] }   // nested YAML layout: not a one-line rename
        var actions: [CodeAction] = []
        func fix(_ title: String, to newKey: String, note: String) {
            actions.append(CodeAction(
                title: title, kind: "quickfix",
                edits: [TextEdit(range: ranges.range(entry.keyRange), replacement: newKey)], preview: note))
        }
        switch ctx.config.metadata.match(entry.key) {
        case .exact(let p):
            if let r = p.deprecation?.replacement { fix("Replace deprecated '\(entry.key)' with '\(r)'", to: r, note: "The replacement may bind a different type or default; check the property's documentation.") }
        case .unknown:
            if let s = ctx.config.suggestion(for: entry.key) { fix("Change '\(entry.key)' to '\(s)'", to: s, note: "Closest known property.") }
        default:
            break
        }
        _ = file
        return actions
    }
}
