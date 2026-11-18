import EditorIntelligence
import Foundation

/// Go to Definition from an injected parameter or field *name* to the bean(s) that satisfy it.
///
/// It answers only when the caret is on the declared name of a Spring injection point (where Java's
/// own provider can only return the declaration itself) and the model has candidates. A type name,
/// a call or anything else is left to Java. One candidate navigates; several (ambiguous or
/// conditional) come back as a list for the host's candidate picker.
public struct SpringNavigationProvider: NavigationProvider {
    public let name = "spring"
    private let indexer: SpringWorkspaceIndexer

    public init(indexer: SpringWorkspaceIndexer) { self.indexer = indexer }

    public func isPrimary(for context: NavigationContext) -> Bool {
        context.document.languageIdentifier == "java"
    }

    public func provide(context: NavigationContext) async -> NavigationResult? {
        guard context.kind == .definition || context.kind == .implementation || context.kind == .references,
              context.document.languageIdentifier == "java",
              let url = context.document.url?.standardizedFileURL, await indexer.contains(url) else { return nil }
        let text = context.document.text
        await indexer.ingest(url: url, text: text)
        let byte = Self.byteOffset(utf16: context.cursor.position.utf16Offset, in: text)
        let model = await indexer.store.model(for: url)
        if context.kind == .references { return Self.consumers(at: byte, in: url, model: model, document: context.document, text: text) }
        guard let point = model.injectionPoint(in: url, atByte: byte) else { return nil }
        let beans = model.candidates(for: point)
        guard !beans.isEmpty else { return nil }
        var cache: [URL: SpringTextRanges] = [url: SpringTextRanges(text: text)]
        let locations: [Location] = beans.compactMap { bean in
            let target = bean.location.url
            if cache[target] == nil, let t = try? String(contentsOf: target, encoding: .utf8) { cache[target] = SpringTextRanges(text: t) }
            guard let ranges = cache[target] else { return nil }
            return Location(
                documentID: target == url ? context.document.id : DocumentID(), url: target,
                range: ranges.range(bean.location.byteRange), displayName: "\(bean.name) — \(bean.type.simpleName)")
        }
        switch locations.count {
        case 0: return nil
        case 1: return .single(locations[0])
        default: return .multiple(locations)
        }
    }

    /// Find Usages on a bean declaration (its class name or `@Bean` method name): the injection points that receive it.
    /// They are added to the language's own usages by the registry, labelled so the Usages list says why they match.
    static func consumers(at byte: Int, in url: URL, model: SpringModel, document: Document, text: String) -> NavigationResult? {
        guard let bean = model.beans.first(where: {
            $0.location.url == url && ($0.location.byteRange.contains(byte) || $0.location.byteRange.upperBound == byte)
        }) else { return nil }
        var cache: [URL: (SpringTextRanges, [Substring])] = [:]
        func lines(_ u: URL) -> (SpringTextRanges, [Substring])? {
            if let c = cache[u] { return c }
            let t = u == url ? text : ((try? String(contentsOf: u, encoding: .utf8)) ?? "")
            guard !t.isEmpty else { return nil }
            let entry = (SpringTextRanges(text: t), t.split(separator: "\n", omittingEmptySubsequences: false))
            cache[u] = entry
            return entry
        }
        let locations: [Location] = model.consumers(of: bean.id).compactMap { point in
            guard let (ranges, all) = lines(point.location.url) else { return nil }
            let range = ranges.range(point.nameRange)
            let lineText = range.start.line < all.count ? String(all[range.start.line]) : ""
            let certain: Bool
            if case .resolved? = model.resolutions[point] { certain = true } else { certain = false }
            let owner = model.bean(point.owner)?.name ?? point.owner.raw
            return Location(
                documentID: point.location.url == url ? document.id : DocumentID(), url: point.location.url, range: range,
                displayName: "\(owner).\(point.name)",
                usage: .init(kindLabel: "Spring injection", isAmbiguous: !certain, lineText: lineText,
                             matchRange: NSRange(location: range.start.column, length: max(1, range.end.column - range.start.column)),
                             line: range.start.line))
        }
        switch locations.count {
        case 0: return nil
        case 1: return .single(locations[0])
        default: return .multiple(locations)
        }
    }

    static func byteOffset(utf16: Int, in text: String) -> Int {
        let u = text.utf16
        let clamped = max(0, min(utf16, u.count))
        let index = u.index(u.startIndex, offsetBy: clamped)
        return text.utf8.distance(from: text.utf8.startIndex, to: index)
    }
}
