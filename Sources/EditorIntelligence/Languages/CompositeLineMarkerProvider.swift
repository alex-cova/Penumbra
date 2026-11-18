import Foundation

/// Several services' gutter markers for one language, merged.
///
/// Line markers used to be a single slot per language: the first service that provided any won, so a
/// framework layer (Spring, JPA, …) could not add a marker without replacing Java's. The registry now hands
/// the host one composite when more than one ready service provides markers, and the provider itself when only
/// one does, so nothing changes for a language with a single owner.
///
/// Rules: markers from every provider are concatenated and ordered by line then anchor; a marker that repeats
/// another's (same kind, line and anchor) is dropped in favour of the earlier provider's; a provider that
/// answers `nil` (cancelled, or the file does not parse) is skipped, and the composite answers `nil` only when
/// every provider did, so the host keeps its previous markers instead of clearing the gutter. Each marker's payload
/// is wrapped so `siblingTargets` reaches the provider that produced it.
public struct CompositeLineMarkerProvider: LineMarkerProviding {
    public let providers: [any LineMarkerProviding]

    public init(_ providers: [any LineMarkerProviding]) { self.providers = providers }

    struct Payload: Sendable { let provider: Int; let inner: (any Sendable)? }

    public func lineMarkers(source: String, fileURL: URL?, kinds: Set<LineMarkerKind>) async -> [LineMarker]? {
        let results = await withTaskGroup(of: (Int, [LineMarker]?).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { (index, await provider.lineMarkers(source: source, fileURL: fileURL, kinds: kinds)) }
            }
            var collected: [(Int, [LineMarker]?)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }
        }
        if Task.isCancelled { return nil }
        guard results.contains(where: { $0.1 != nil }) else { return nil }
        struct Key: Hashable { let kind: LineMarkerKind; let line: Int; let anchor: Int }
        var seen = Set<Key>()
        var merged: [LineMarker] = []
        for (index, markers) in results {
            for m in markers ?? [] where seen.insert(Key(kind: m.kind, line: m.line, anchor: m.anchorUTF16Offset)).inserted {
                merged.append(LineMarker(kind: m.kind, descriptor: m.descriptor, line: m.line, anchorUTF16Offset: m.anchorUTF16Offset,
                                         tooltip: m.tooltip, payload: Payload(provider: index, inner: m.payload)))
            }
        }
        return merged.sorted { ($0.line, $0.anchorUTF16Offset) < ($1.line, $1.anchorUTF16Offset) }
    }

    public func siblingTargets(of marker: LineMarker, source: String, fileURL: URL?, documentID: DocumentID) async -> [Location] {
        guard let payload = marker.payload as? Payload, providers.indices.contains(payload.provider) else { return [] }
        let unwrapped = LineMarker(kind: marker.kind, descriptor: marker.descriptor, line: marker.line, anchorUTF16Offset: marker.anchorUTF16Offset,
                                   tooltip: marker.tooltip, payload: payload.inner)
        return await providers[payload.provider].siblingTargets(of: unwrapped, source: source, fileURL: fileURL, documentID: documentID)
    }

    public func menu(for marker: LineMarker, source: String, fileURL: URL?, documentID: DocumentID) async -> [LineMarkerMenuItem] {
        guard let payload = marker.payload as? Payload, providers.indices.contains(payload.provider) else { return [] }
        let unwrapped = LineMarker(kind: marker.kind, descriptor: marker.descriptor, line: marker.line, anchorUTF16Offset: marker.anchorUTF16Offset,
                                   tooltip: marker.tooltip, payload: payload.inner)
        return await providers[payload.provider].menu(for: unwrapped, source: source, fileURL: fileURL, documentID: documentID)
    }
}
