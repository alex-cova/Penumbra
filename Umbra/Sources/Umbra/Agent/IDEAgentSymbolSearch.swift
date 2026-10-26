import EditorIntelligence
import Foundation
import JavaIntelligence
import SwiftIntelligence
import TypeScriptIntelligence

/// A project declaration the agent can find by name, located in the file as it is now.
struct IDEAgentSymbol: Sendable, Equatable {
    var name: String
    /// `demo.Calc` for a Java type, `demo.Calc.add` for a member, `Container.name` for Swift and TypeScript.
    var qualifiedName: String
    var kind: String
    var isType: Bool
    /// `(int, int): int` for a method, `: List<Order>` for a field, `extends A implements B` for a type.
    var detail: String?
    var fileURL: URL
    /// 1-based line of the name in the live text; `nil` when the file no longer holds the declaration.
    var line: Int?
    /// UTF-16 offset of the name in the live text.
    var utf16Offset: Int?
    /// The index placed it elsewhere than the live text does (the file changed since it was indexed).
    var movedSinceIndexing = false
}

/// The languages the navigation tools answer for, by file extension.
enum IDEAgentSourceLanguage {
    static func identifier(forPath path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "java": "java"
        case "swift": "swift"
        case "ts", "tsx", "mts", "cts": "typescript"
        case "js", "jsx", "mjs", "cjs": "javascript"
        default: nil
        }
    }
}

/// Which indexes are still building, as the tools tell the model. Pure, so the wording is tested
/// without a window.
struct IDEAgentIndexReadiness: Sendable, Equatable {
    var pending: Set<IDEIndexKind> = []

    static let ready = IDEAgentIndexReadiness()

    var isReady: Bool { pending.isEmpty }

    /// The parts a *name* lookup reads. Nothing found while one of these builds may only mean "not yet".
    private static let nameParts: Set<IDEIndexKind> = [.javaSources, .swift, .typeScript]

    /// The parts that matter for `language` (a file's `IDEAgentSourceLanguage` id), or for a name
    /// lookup in general when it is `nil`.
    func pending(forLanguage language: String?) -> Set<IDEIndexKind> {
        switch language {
        case "java": pending.intersection([.javaSources, .javaDependencies, .javaUsages])
        case "swift": pending.intersection([.swift])
        case "typescript", "javascript": pending.intersection([.typeScript])
        default: pending.intersection(Self.nameParts)
        }
    }

    /// The parts that matter for these symbols' languages (all name parts when there are none).
    func pending(for symbols: [IDEAgentSymbol]) -> Set<IDEIndexKind> {
        guard !symbols.isEmpty else { return pending(forLanguage: nil) }
        return symbols.reduce(into: Set<IDEIndexKind>()) {
            $0.formUnion(pending(forLanguage: IDEAgentSourceLanguage.identifier(forPath: $1.fileURL.path)))
        }
    }

    /// Whether usages and implementations of a `language` symbol can be missing because an index is still building.
    func blocksUsages(forLanguage language: String?) -> Bool {
        switch language {
        case "java": !pending.isDisjoint(with: [.javaSources, .javaUsages])
        default: !pending(forLanguage: language).isEmpty
        }
    }

    static func describe(_ parts: Set<IDEIndexKind>) -> String {
        IDEIndexKind.allCases.filter(parts.contains).map(\.label).joined(separator: ", ")
    }
}

/// Name search over the project's indexes, as `find_symbol` and `explore_symbol` use it. The window
/// backs it with the Java, Swift and TypeScript indexes; tests use a fake.
protocol IDEAgentSymbolSearching: Sendable {
    /// Project declarations whose name matches `query`, best first, located in the live text. With
    /// `exactName` only declarations named exactly `query` (case-sensitive) are returned.
    func symbols(matching query: String, exactName: Bool, limit: Int) async -> [IDEAgentSymbol]
    /// The file as it is now: the open buffer, else the disk.
    func liveText(of file: URL) async -> String?
    /// Every type of the file with its members; empty for a language without a structure provider.
    func structure(file: URL, source: String) async -> [StructureNode]
    /// Which indexes are building right now.
    func indexReadiness() async -> IDEAgentIndexReadiness
}

/// Reads line numbers out of one text without scanning it again for every offset.
struct IDEAgentLineIndex {
    private var starts: [Int] = [0]

    init(_ text: String) {
        let ns = text as NSString
        var index = 0
        while index < ns.length {
            let unit = ns.character(at: index)
            if unit == 10 {
                starts.append(index + 1)
            } else if unit == 13 {
                if index + 1 < ns.length, ns.character(at: index + 1) == 10 { index += 1 }
                starts.append(index + 1)
            }
            index += 1
        }
    }

    var lineCount: Int { starts.count }

    /// 1-based line holding the UTF-16 `offset`.
    func line(at offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    /// UTF-16 offset where 1-based `line` starts.
    func start(ofLine line: Int) -> Int { starts[min(max(line, 1), starts.count) - 1] }
}

struct IDEIndexAgentSymbolSearch: IDEAgentSymbolSearching {
    var javaIndex: JavaIndex?
    var swiftIndex: SwiftIndex?
    var typeScriptIndex: TypeScriptIndex?
    var text: @Sendable (URL) async -> String?
    var structureProvider: @Sendable (String?) async -> (any StructureProviding)?
    var readiness: @Sendable () async -> IDEAgentIndexReadiness

    /// A declaration as the index reports it, before it is found in the live text.
    private struct Candidate {
        var symbol: IDEAgentSymbol
        /// Where the index says the name is (UTF-8), when it says.
        var indexedBytes: Range<Int>?
        var javaMember: JavaMemberMatch?
    }

    func liveText(of file: URL) async -> String? { await text(file) }

    func indexReadiness() async -> IDEAgentIndexReadiness { await readiness() }

    func structure(file: URL, source: String) async -> [StructureNode] {
        let language = IDEAgentSourceLanguage.identifier(forPath: file.path)
        guard let provider = await structureProvider(language) else { return [] }
        return await provider.allStructure(forSource: source) ?? []
    }

    func symbols(matching query: String, exactName: Bool, limit: Int) async -> [IDEAgentSymbol] {
        guard !query.isEmpty, limit > 0 else { return [] }
        var candidates: [Candidate] = []
        if let javaIndex { candidates += await javaCandidates(javaIndex, query: query) }
        if let swiftIndex {
            for symbol in await swiftIndex.symbols(matching: query, limit: 300) {
                candidates.append(indexed(
                    name: symbol.name, container: symbol.container, kind: String(describing: symbol.kind),
                    isType: symbol.kind.isTypeLike, url: symbol.url, bytes: symbol.nameBytes))
            }
        }
        if let typeScriptIndex {
            for symbol in await typeScriptIndex.symbols(matching: query, limit: 300) {
                let kind = String(describing: symbol.kind)
                candidates.append(indexed(
                    name: symbol.name, container: symbol.container, kind: kind,
                    isType: ["class", "interface", "typeAlias", "enum"].contains(kind), url: symbol.url, bytes: symbol.nameBytes))
            }
        }
        if exactName { candidates.removeAll { $0.symbol.name != query } }
        // Exact names first, then types before members, each keeping the index's own ranking.
        let ranked = candidates.enumerated().sorted { lhs, rhs in
            let l = (lhs.element.symbol.name == query ? 0 : 1, lhs.element.symbol.isType ? 0 : 1, lhs.offset)
            let r = (rhs.element.symbol.name == query ? 0 : 1, rhs.element.symbol.isType ? 0 : 1, rhs.offset)
            return l < r
        }.prefix(limit).map(\.element)

        var located: [IDEAgentSymbol] = []
        var texts: [URL: Located] = [:]
        for candidate in ranked {
            let url = candidate.symbol.fileURL
            if texts[url] == nil { texts[url] = await Located(text: text(url)) }
            located.append(locate(candidate, in: texts[url]))
        }
        return located
    }

    // MARK: Candidates

    private func indexed(
        name: String, container: String, kind: String, isType: Bool, url: URL, bytes: Range<Int>
    ) -> Candidate {
        Candidate(
            symbol: IDEAgentSymbol(
                name: name, qualifiedName: container.isEmpty ? name : "\(container).\(name)",
                kind: kind, isType: isType, detail: nil, fileURL: url),
            indexedBytes: bytes)
    }

    private func javaCandidates(_ index: JavaIndex, query: String) async -> [Candidate] {
        var found: [Candidate] = []
        // Project classes are outranked by same-tier JDK ones only through precedence, so ask for
        // more than we keep before dropping everything that is not a project source.
        for match in await index.classes(matching: query, limit: 300) {
            let stub = match.stub
            guard case .source(let url, let nameRange) = stub.origin else { continue }
            var parts: [String] = []
            if let superclass = stub.superclass, superclass.simpleDisplayName != "Object" {
                parts.append("extends \(superclass.simpleDisplayName)")
            }
            if !stub.interfaces.isEmpty {
                let word = stub.kind == .interfaceKind ? "extends" : "implements"
                parts.append("\(word) " + stub.interfaces.map(\.simpleDisplayName).joined(separator: ", "))
            }
            found.append(Candidate(
                symbol: IDEAgentSymbol(
                    name: stub.simpleName, qualifiedName: stub.qualifiedName, kind: Self.kindName(stub.kind), isType: true,
                    detail: parts.isEmpty ? nil : parts.joined(separator: " "), fileURL: url),
                indexedBytes: nameRange))
        }
        for member in await index.members(matching: query, limit: 300) {
            found.append(Candidate(
                symbol: IDEAgentSymbol(
                    name: member.name, qualifiedName: "\(member.ownerQualifiedName).\(member.name)",
                    kind: Self.kindName(member.kind), isType: false,
                    detail: IDEJavaMembersPaletteSource.detail(of: member), fileURL: member.url),
                javaMember: member))
        }
        return found
    }

    private static func kindName(_ kind: JavaTypeKind) -> String {
        switch kind {
        case .classKind: "class"
        case .interfaceKind: "interface"
        case .enumKind: "enum"
        case .recordKind: "record"
        case .annotationKind: "annotation"
        }
    }

    private static func kindName(_ kind: JavaMemberKind) -> String {
        switch kind {
        case .method: "method"
        case .field: "field"
        case .enumConstant: "enum constant"
        case .recordComponent: "record component"
        }
    }

    // MARK: Locating

    /// One file's live text with what locating needs from it, computed once per file.
    private struct Located {
        let text: String?
        let utf8: [UInt8]
        let lines: IDEAgentLineIndex

        init(text: String?) {
            self.text = text
            utf8 = Array((text ?? "").utf8)
            lines = IDEAgentLineIndex(text ?? "")
        }

        func utf16Offset(ofByte byte: Int) -> Int {
            String(decoding: utf8[..<min(max(byte, 0), utf8.count)], as: UTF8.self).utf16.count
        }

        func spells(_ name: String, at bytes: Range<Int>) -> Bool {
            bytes.lowerBound >= 0 && bytes.upperBound <= utf8.count && Array(utf8[bytes]) == Array(name.utf8)
        }
    }

    private static let declarationKeywords = [
        "class", "interface", "enum", "record", "struct", "protocol", "actor", "type", "function", "func", "namespace",
    ]

    private func locate(_ candidate: Candidate, in file: Located?) -> IDEAgentSymbol {
        var symbol = candidate.symbol
        guard let file, file.text != nil else { return symbol }
        var bytes: Range<Int>?
        if let member = candidate.javaMember {
            // The locator falls back to the owner's name when the member is gone; only the member counts.
            if let range = JavaMemberLocator.nameRange(of: member, in: file.text ?? ""), file.spells(symbol.name, at: range) {
                bytes = range
            }
        } else if let indexed = candidate.indexedBytes {
            if file.spells(symbol.name, at: indexed) {
                bytes = indexed
            } else if let found = Self.findDeclaration(named: symbol.name, in: file.text ?? "") {
                bytes = found
                symbol.movedSinceIndexing = true
            }
        }
        guard let bytes else { return symbol }
        let offset = file.utf16Offset(ofByte: bytes.lowerBound)
        symbol.utf16Offset = offset
        symbol.line = file.lines.line(at: offset)
        return symbol
    }

    /// The UTF-8 range of the first `class Name`-style declaration of `name`, for a file that changed
    /// since the index read it.
    private static func findDeclaration(named name: String, in text: String) -> Range<Int>? {
        let keywords = declarationKeywords.joined(separator: "|")
        let pattern = "(?:\\b(?:\(keywords))|@interface)\\s+(\(NSRegularExpression.escapedPattern(for: name)))(?![A-Za-z0-9_$])"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        let lower = text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound)
        return lower..<(lower + name.utf8.count)
    }
}
