import CoreGraphics
import EditorIntelligence
import Foundation

/// Serializable snapshot of a ``WorkbenchDocument`` for layout restoration.
public struct WorkbenchDocumentSnapshot: Equatable, Codable, Sendable {
    public var id: UUID
    public var documentID: UUID
    public var url: URL?
    public var displayName: String
    public var text: String
    public var languageIdentifier: String?
    public var isDirty: Bool
    public var selectedRangeLocation: Int
    public var selectedRangeLength: Int
    public var scrollOffsetX: CGFloat
    public var scrollOffsetY: CGFloat
    public var isFileBacked: Bool

    public init(
        id: UUID,
        documentID: UUID,
        url: URL? = nil,
        displayName: String,
        text: String,
        languageIdentifier: String? = nil,
        isDirty: Bool = false,
        selectedRangeLocation: Int = 0,
        selectedRangeLength: Int = 0,
        scrollOffsetX: CGFloat = 0,
        scrollOffsetY: CGFloat = 0,
        isFileBacked: Bool = false
    ) {
        self.id = id
        self.documentID = documentID
        self.url = url
        self.displayName = displayName
        self.text = text
        self.languageIdentifier = languageIdentifier
        self.isDirty = isDirty
        self.selectedRangeLocation = selectedRangeLocation
        self.selectedRangeLength = selectedRangeLength
        self.scrollOffsetX = scrollOffsetX
        self.scrollOffsetY = scrollOffsetY
        self.isFileBacked = isFileBacked
    }

    public init(document: WorkbenchDocument) {
        self.id = document.id
        self.documentID = document.documentID.uuid
        self.url = document.url
        self.displayName = document.displayName
        self.text = document.text
        self.languageIdentifier = document.languageIdentifier
        self.isDirty = document.isDirty
        self.selectedRangeLocation = document.selectedRange.location
        self.selectedRangeLength = document.selectedRange.length
        self.scrollOffsetX = document.scrollOffset.x
        self.scrollOffsetY = document.scrollOffset.y
        self.isFileBacked = document.isFileBacked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        documentID = try container.decode(UUID.self, forKey: .documentID)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        displayName = try container.decode(String.self, forKey: .displayName)
        text = try container.decode(String.self, forKey: .text)
        languageIdentifier = try container.decodeIfPresent(String.self, forKey: .languageIdentifier)
        isDirty = try container.decode(Bool.self, forKey: .isDirty)
        selectedRangeLocation = try container.decode(Int.self, forKey: .selectedRangeLocation)
        selectedRangeLength = try container.decode(Int.self, forKey: .selectedRangeLength)
        scrollOffsetX = try container.decode(CGFloat.self, forKey: .scrollOffsetX)
        scrollOffsetY = try container.decode(CGFloat.self, forKey: .scrollOffsetY)
        isFileBacked = try container.decodeIfPresent(Bool.self, forKey: .isFileBacked) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(documentID, forKey: .documentID)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(languageIdentifier, forKey: .languageIdentifier)
        try container.encode(isDirty, forKey: .isDirty)
        try container.encode(selectedRangeLocation, forKey: .selectedRangeLocation)
        try container.encode(selectedRangeLength, forKey: .selectedRangeLength)
        try container.encode(scrollOffsetX, forKey: .scrollOffsetX)
        try container.encode(scrollOffsetY, forKey: .scrollOffsetY)
        try container.encode(isFileBacked, forKey: .isFileBacked)
    }

    public func makeDocument(language: TreeSitterLanguage? = nil) -> WorkbenchDocument {
        let document = WorkbenchDocument(
            id: id,
            documentID: DocumentID(documentID),
            url: url,
            displayName: displayName,
            text: text,
            language: language,
            languageIdentifier: languageIdentifier,
            isDirty: isDirty,
            selectedRange: NSRange(location: selectedRangeLocation, length: selectedRangeLength),
            scrollOffset: CGPoint(x: scrollOffsetX, y: scrollOffsetY)
        )
        document.isFileBacked = isFileBacked
        return document
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case documentID
        case url
        case displayName
        case text
        case languageIdentifier
        case isDirty
        case selectedRangeLocation
        case selectedRangeLength
        case scrollOffsetX
        case scrollOffsetY
        case isFileBacked
    }
}

/// Serializable snapshot of an ``EditorPane`` tab group.
public struct EditorPaneSnapshot: Equatable, Codable, Sendable {
    public var id: UUID
    public var documents: [WorkbenchDocumentSnapshot]
    public var selectedDocumentID: UUID?
    public var temporaryDocumentID: UUID?
    public var tabHistoryEntries: [UUID]
    public var tabHistoryOffset: Int

    public init(
        id: UUID,
        documents: [WorkbenchDocumentSnapshot],
        selectedDocumentID: UUID? = nil,
        temporaryDocumentID: UUID? = nil,
        tabHistoryEntries: [UUID] = [],
        tabHistoryOffset: Int = 0
    ) {
        self.id = id
        self.documents = documents
        self.selectedDocumentID = selectedDocumentID
        self.temporaryDocumentID = temporaryDocumentID
        self.tabHistoryEntries = tabHistoryEntries
        self.tabHistoryOffset = tabHistoryOffset
    }

    public init(pane: EditorPane) {
        self.id = pane.id
        self.documents = pane.documents.map(WorkbenchDocumentSnapshot.init)
        self.selectedDocumentID = pane.selectedDocumentID
        self.temporaryDocumentID = pane.temporaryDocumentID
        self.tabHistoryEntries = pane.tabHistory.snapshotEntries()
        self.tabHistoryOffset = pane.tabHistory.snapshotOffset()
    }

    public func makePane(languageResolver: (WorkbenchDocumentSnapshot) -> TreeSitterLanguage? = { _ in nil }) -> EditorPane {
        let pane = EditorPane(id: id)
        pane.documents = documents.map { snapshot in
            snapshot.makeDocument(language: languageResolver(snapshot))
        }
        pane.selectedDocumentID = selectedDocumentID
        pane.temporaryDocumentID = temporaryDocumentID
        pane.tabHistory.restore(entries: tabHistoryEntries, offset: tabHistoryOffset)
        return pane
    }
}

/// Serializable editor layout tree for state restoration.
public struct EditorRestorationState: Equatable, Codable, Sendable {
    public var activePaneID: UUID
    public var layout: EditorLayoutSnapshot

    public init(activePaneID: UUID, layout: EditorLayoutSnapshot) {
        self.activePaneID = activePaneID
        self.layout = layout
    }
}

public enum EditorLayoutSnapshot: Equatable, Codable, Sendable {
    case pane(EditorPaneSnapshot)
    case vertical(EditorSplitSnapshot)
    case horizontal(EditorSplitSnapshot)

    public init(layout: EditorLayout) {
        switch layout {
        case .pane(let pane):
            self = .pane(EditorPaneSnapshot(pane: pane))
        case .vertical(let data):
            self = .vertical(EditorSplitSnapshot(data: data))
        case .horizontal(let data):
            self = .horizontal(EditorSplitSnapshot(data: data))
        }
    }

    public func makeLayout(
        languageResolver: (WorkbenchDocumentSnapshot) -> TreeSitterLanguage? = { _ in nil }
    ) -> EditorLayout {
        switch self {
        case .pane(let snapshot):
            return .pane(snapshot.makePane(languageResolver: languageResolver))
        case .vertical(let split):
            return .vertical(split.makeSplitData(languageResolver: languageResolver))
        case .horizontal(let split):
            return .horizontal(split.makeSplitData(languageResolver: languageResolver))
        }
    }
}

public struct EditorSplitSnapshot: Equatable, Codable, Sendable {
    public var axis: EditorLayoutAxis
    public var children: [EditorLayoutSnapshot]

    public init(axis: EditorLayoutAxis, children: [EditorLayoutSnapshot]) {
        self.axis = axis
        self.children = children
    }

    public init(data: EditorSplitData) {
        self.axis = data.axis
        self.children = data.children.map(EditorLayoutSnapshot.init)
    }

    public func makeSplitData(
        languageResolver: (WorkbenchDocumentSnapshot) -> TreeSitterLanguage? = { _ in nil }
    ) -> EditorSplitData {
        EditorSplitData(axis: axis, children: children.map { $0.makeLayout(languageResolver: languageResolver) })
    }
}
