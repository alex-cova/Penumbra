import EditorIntelligence
import Foundation

// Java's providers speak the generic feature protocols (`LanguageFeatures.swift` in
// `EditorIntelligence`) by mapping their own types to the generic ones. The Java types stay: the
// providers' other callers, and the tests, still use them.

// MARK: - Semantic highlighting

extension JavaSemanticTokenProvider: SemanticTokenProviding {
    public func semanticHighlights(forSource source: String) async -> [SemanticHighlight]? {
        await tokens(for: source)?.map { SemanticHighlight(range: $0.range, highlightName: $0.highlightName) }
    }
}

// MARK: - Gutter line markers

extension JavaLineMarkerProvider: LineMarkerProviding {
    public func lineMarkers(source: String, fileURL: URL?, kinds: Set<LineMarkerKind>) async -> [LineMarker]? {
        await markers(source: source, fileURL: fileURL, kinds: kinds)?.map { marker in
            LineMarker(
                kind: marker.kind, line: marker.line, anchorUTF16Offset: marker.anchorUTF16Offset,
                tooltip: marker.tooltip, payload: marker
            )
        }
    }

    public func siblingTargets(of marker: LineMarker, source: String, fileURL: URL?, documentID: DocumentID) async -> [Location] {
        guard let javaMarker = marker.payload as? JavaLineMarker else { return [] }
        return await siblingTargets(of: javaMarker, source: source, fileURL: fileURL, documentID: documentID)
    }
}

// MARK: - Structure

extension JavaStructureProvider: StructureProviding {
    public func structure(forSource source: String, atUTF16Offset utf16Offset: Int) async -> StructureNode? {
        guard let root = structure(for: source, atUTF16Offset: utf16Offset) else { return nil }
        return Self.generic(root, using: Self.offsetConverter(for: source))
    }

    public func allStructure(forSource source: String) async -> [StructureNode]? {
        guard let roots = allStructure(for: source) else { return nil }
        let convert = Self.offsetConverter(for: source)
        return roots.map { Self.generic($0, using: convert) }
    }

    /// Byte offsets to UTF-16 offsets. A file of ASCII alone (the usual case) maps one to one.
    private static func offsetConverter(for source: String) -> (Int) -> Int {
        if source.utf8.count == source.utf16.count { return { $0 } }
        return { JavaNavigationText.utf16Offset(forByte: $0, in: source) }
    }

    private static func generic(_ node: JavaStructureNode, using convert: (Int) -> Int) -> StructureNode {
        StructureNode(
            id: node.id, title: node.title,
            kind: StructureKind(rawValue: node.kind.rawValue) ?? .type,
            nameRange: convert(node.nameByteRange.lowerBound)..<convert(node.nameByteRange.upperBound),
            bodyRange: convert(node.bodyByteRange.lowerBound)..<convert(node.bodyByteRange.upperBound),
            children: node.children.map { generic($0, using: convert) }
        )
    }
}

// MARK: - Hierarchies

extension JavaTypeHierarchyProvider: TypeHierarchyProviding {
    public func rootItem(source: String, fileURL: URL?, utf16Offset: Int) async -> HierarchyItem? {
        await rootType(source: source, fileURL: fileURL, utf16Offset: utf16Offset).map(Self.item)
    }

    public func supertypes(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] {
        guard let node = item.payload as? JavaTypeHierarchyNode else { return [] }
        return await supertypes(of: node, file: file).map(Self.item)
    }

    public func subtypes(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] {
        guard let node = item.payload as? JavaTypeHierarchyNode else { return [] }
        return await subtypes(of: node, file: file).map(Self.item)
    }

    public func location(of item: HierarchyItem, file: URL?) async -> HierarchyLocation? {
        guard let node = item.payload as? JavaTypeHierarchyNode,
              let location = await location(of: node, file: file) else { return nil }
        return HierarchyLocation(url: location.url, range: location.range)
    }

    private static func item(_ node: JavaTypeHierarchyNode) -> HierarchyItem {
        let kind: HierarchyItemKind
        switch node.kind {
        case .classKind: kind = .classType
        case .interfaceKind: kind = .interfaceType
        case .enumKind: kind = .enumType
        case .recordKind: kind = .recordType
        case .annotationKind: kind = .annotationType
        }
        let origin: HierarchyOrigin
        let badge: String?
        switch node.origin {
        case .source: (origin, badge) = (.project, nil)
        case .jar: (origin, badge) = (.library, "jar")
        case .jdk: (origin, badge) = (.runtime, "JDK")
        }
        return HierarchyItem(
            id: node.id, name: node.displayName, detail: node.packageName, kind: kind,
            origin: origin, badge: badge, payload: node
        )
    }
}

extension JavaCallHierarchyProvider: CallHierarchyProviding {
    public func rootItem(source: String, fileURL: URL?, utf16Offset: Int) async -> HierarchyItem? {
        await rootMethod(source: source, fileURL: fileURL, utf16Offset: utf16Offset).map(Self.item)
    }

    public func callers(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] {
        guard let node = item.payload as? JavaCallHierarchyNode else { return [] }
        return await callers(of: node, file: file).map(Self.item)
    }

    public func callees(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] {
        guard let node = item.payload as? JavaCallHierarchyNode else { return [] }
        return await callees(of: node, file: file).map(Self.item)
    }

    public func location(of item: HierarchyItem, file: URL?) async -> HierarchyLocation? {
        guard let node = item.payload as? JavaCallHierarchyNode,
              let location = await location(of: node, file: file) else { return nil }
        return HierarchyLocation(url: location.url, range: location.range)
    }

    private static func item(_ node: JavaCallHierarchyNode) -> HierarchyItem {
        let origin: HierarchyOrigin
        switch node.origin {
        case .source: origin = .project
        case .jar: origin = .library
        case .jdk: origin = .runtime
        case .ambiguous: origin = .ambiguous
        }
        return HierarchyItem(
            id: node.id, name: node.displayName, detail: node.declaringClass, kind: .method,
            origin: origin, payload: node
        )
    }
}
