import CoreGraphics
import DiagramKit
import Foundation

/// What a diagram box stands for. Colors and shapes are derived from it at draw time, so the same
/// document looks right in light and dark appearance.
nonisolated enum IDEDiagramNodeKind: String, Codable, Sendable, Equatable {
    case classType
    case abstractClass
    case interfaceType
    case enumType
    case recordType
    case annotationType
    /// A type that comes from the JDK or a dependency jar: drawn as a name only.
    case externalType
    case project
    case library
    /// A library whose version Gradle replaced while resolving.
    case replacedLibrary
    /// A dependency Gradle could not resolve.
    case unresolvedLibrary

    var isType: Bool {
        switch self {
        case .classType, .abstractClass, .interfaceType, .enumType, .recordType, .annotationType, .externalType:
            true
        case .project, .library, .replacedLibrary, .unresolvedLibrary:
            false
        }
    }
}

nonisolated enum IDEDiagramEdgeKind: String, Codable, Sendable, Equatable, CaseIterable {
    case inheritance
    case realization
    case association
    case aggregation
    case dependency
    case projectDependency
    case libraryDependency
    /// Gradle chose another version than the one requested.
    case replaced

    var isDashed: Bool {
        switch self {
        case .realization, .dependency, .replaced: true
        default: false
        }
    }

    /// Supertype edges point from the subtype up; layouts rank the destination above the source.
    var ranksDestinationFirst: Bool {
        self == .inheritance || self == .realization
    }
}

nonisolated struct IDEDiagramNode: Codable, Sendable, Equatable, Identifiable, DiagramNode, ClipboardPasteableNode {
    var id: UUID
    var frame: CGRect
    /// What the node was made from (qualified type name, Gradle project path, `group:name`); also
    /// what its UUID is derived from.
    var key: String
    var kind: IDEDiagramNodeKind
    var title: String
    var subtitle: String
    var attributes: [String]
    var methods: [String]
    var fileURL: URL?

    init(
        key: String,
        kind: IDEDiagramNodeKind,
        title: String,
        subtitle: String = "",
        attributes: [String] = [],
        methods: [String] = [],
        fileURL: URL? = nil,
        origin: CGPoint = .zero
    ) {
        self.id = IDEDiagramIdentity.id(for: "node:" + key)
        self.key = key
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.attributes = attributes
        self.methods = methods
        self.fileURL = fileURL
        self.frame = CGRect(origin: origin, size: IDEDiagramNodeMetrics.size(
            title: title, subtitle: subtitle, attributes: attributes, methods: methods, kind: kind
        ))
    }

    func pasting(newID: UUID, frame: CGRect) -> IDEDiagramNode {
        var copy = self
        copy.id = newID
        copy.frame = frame
        return copy
    }
}

nonisolated struct IDEDiagramEdge: Codable, Sendable, Equatable, Identifiable, DiagramEdge, ClipboardPasteableEdge {
    var id: UUID
    var sourceID: UUID
    var destinationID: UUID
    var kind: IDEDiagramEdgeKind
    var label: String

    init(sourceID: UUID, destinationID: UUID, kind: IDEDiagramEdgeKind, label: String = "") {
        self.id = IDEDiagramIdentity.id(for: "edge:\(kind.rawValue):\(sourceID):\(destinationID):\(label)")
        self.sourceID = sourceID
        self.destinationID = destinationID
        self.kind = kind
        self.label = label
    }

    func pasting(newID: UUID, sourceID: UUID, destinationID: UUID) -> IDEDiagramEdge {
        var copy = self
        copy.id = newID
        copy.sourceID = sourceID
        copy.destinationID = destinationID
        return copy
    }
}

nonisolated struct IDEDiagramDocument: Codable, Sendable, Equatable, MutableDiagramDocument {
    var meta: DiagramMeta
    var canvas: CanvasSettings
    var nodes: [IDEDiagramNode]
    var edges: [IDEDiagramEdge]

    init(
        meta: DiagramMeta = DiagramMeta(title: "Diagram"),
        canvas: CanvasSettings = CanvasSettings(),
        nodes: [IDEDiagramNode] = [],
        edges: [IDEDiagramEdge] = []
    ) {
        self.meta = meta
        self.canvas = canvas
        self.nodes = nodes
        self.edges = edges
    }

    /// No grid or snapping: the layout places the boxes, and a hand-moved box stays where it was dropped.
    static let defaultCanvas = CanvasSettings(
        gridSize: 16, snapEnabled: false, showGrid: false, edgeRouting: .orthogonal, avoidObstacles: true,
        animateLayout: false, showGuides: false
    )

    func node(id: UUID) -> IDEDiagramNode? {
        nodes.first { $0.id == id }
    }

    mutating func touchModified() {
        meta.modifiedAt = .now
    }
}

/// Node and edge UUIDs come from their content, so rebuilding a diagram keeps selection and the
/// viewport pointing at the same boxes.
nonisolated enum IDEDiagramIdentity {
    static func id(for key: String) -> UUID {
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x84222325cbf29ce4
        for byte in key.utf8 {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second &+ UInt64(byte)) &* 0x9e3779b97f4a7c15
            second ^= second >> 29
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: first >> (index * 8))
            bytes[index + 8] = UInt8(truncatingIfNeeded: second >> (index * 8))
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// Box sizes are estimated from the text, since layout needs them before anything is drawn.
nonisolated enum IDEDiagramNodeMetrics {
    static let lineHeight: CGFloat = 15
    static let headerHeight: CGFloat = 30
    static let sectionPadding: CGFloat = 6
    static let horizontalPadding: CGFloat = 10
    static let characterWidth: CGFloat = 6.4
    static let minimumWidth: CGFloat = 120
    static let maximumWidth: CGFloat = 380
    /// Members shown per compartment before "… N more".
    static let maximumLines = 14

    static func size(
        title: String,
        subtitle: String,
        attributes: [String],
        methods: [String],
        kind: IDEDiagramNodeKind
    ) -> CGSize {
        var widest = CGFloat(title.count) * (characterWidth + 0.8)
        if !subtitle.isEmpty { widest = max(widest, CGFloat(subtitle.count) * (characterWidth - 0.6)) }
        for line in displayed(attributes) + displayed(methods) {
            widest = max(widest, CGFloat(line.count) * characterWidth)
        }
        let width = min(maximumWidth, max(minimumWidth, widest + horizontalPadding * 2))

        var height = headerHeight
        if !subtitle.isEmpty { height += lineHeight - 2 }
        if kind.isType, kind != .externalType {
            height += compartmentHeight(attributes.count) + compartmentHeight(methods.count)
        }
        return CGSize(width: width.rounded(.up), height: height.rounded(.up))
    }

    static func compartmentHeight(_ count: Int) -> CGFloat {
        let shown = min(count, maximumLines + (count > maximumLines ? 1 : 0))
        return CGFloat(max(shown, 0)) * lineHeight + sectionPadding * 2
    }

    /// The lines a compartment draws: the first `maximumLines`, then a count of the rest.
    static func displayed(_ lines: [String]) -> [String] {
        guard lines.count > maximumLines else { return lines }
        return Array(lines.prefix(maximumLines)) + ["… \(lines.count - maximumLines) more"]
    }
}
