import Foundation
import CoreGraphics

public enum ExtraFill: Equatable, Sendable {
    case none
    case background
    case foreground
    case muted
    case accent
    case surface
    case border
    case series(Int)
}

public enum ExtraAnchor: String, Sendable {
    case start
    case middle
    case end
}

public struct ExtraPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum ExtraItem: Sendable {
    case rect(x: Double, y: Double, width: Double, height: Double, fill: ExtraFill, stroke: ExtraFill, corner: Double, dashed: Bool)
    case ellipse(x: Double, y: Double, width: Double, height: Double, fill: ExtraFill, stroke: ExtraFill)
    case line(x1: Double, y1: Double, x2: Double, y2: Double, stroke: ExtraFill, width: Double, dashed: Bool)
    case polyline(points: [ExtraPoint], fill: ExtraFill, stroke: ExtraFill, width: Double, closed: Bool)
    case wedge(cx: Double, cy: Double, radius: Double, start: Double, end: Double, fill: ExtraFill, stroke: ExtraFill, innerRadius: Double)
    case text(String, x: Double, y: Double, size: Double, fill: ExtraFill, anchor: ExtraAnchor, weight: Int)
}

public struct ExtraScene: Sendable {
    public var width: Double
    public var height: Double
    public var items: [ExtraItem]

    public init(width: Double, height: Double, items: [ExtraItem]) {
        self.width = width
        self.height = height
        self.items = items
    }

    public static let empty = ExtraScene(width: 120, height: 80, items: [])
}

public enum ExtraParsed: Sendable {
    case pie(PieChart)
    case gantt(GanttChart)
    case gitGraph(GitGraphChart)
    case journey(JourneyChart)
    case mindmap(MindmapChart)
    case timeline(TimelineChart)
    case quadrant(QuadrantChart)
    case sankey(SankeyChart)
    case radar(RadarChart)
    case treemap(TreemapChart)
    case venn(VennChart)
    case packet(PacketChart)
    case block(BlockChart)
    case requirement(RequirementChart)
    case architecture(ArchitectureChart)
    case c4(C4Chart)
    case kanban(KanbanChart)
    case usecase(UseCaseChart)
    case treeView(TreeViewChart)
    case ishikawa(IshikawaChart)
    case cynefin(CynefinChart)
    case wardley(WardleyChart)
    case eventmodeling(EventModelChart)
    case railroad(RailroadChart)
}

// MARK: - Parsed models

public struct PieSlice: Sendable {
    public var label: String
    public var value: Double
}

public struct PieChart: Sendable {
    public var title: String?
    public var showData: Bool
    public var slices: [PieSlice]
}

public struct GanttTask: Sendable {
    public var name: String
    public var id: String
    public var startDay: Double
    public var durationDays: Double
    public var section: String
    public var milestone: Bool
}

public struct GanttChart: Sendable {
    public var title: String?
    public var tasks: [GanttTask]
    public var markers: [Double]
}

public struct GitCommit: Sendable {
    public var id: String
    public var branch: String
    public var message: String
    public var order: Int
}

public struct GitGraphChart: Sendable {
    public var direction: String
    public var commits: [GitCommit]
    public var branches: [String]
    public var merges: [(from: String, to: String, at: Int)]
}

public struct JourneyTask: Sendable {
    public var section: String
    public var name: String
    public var score: Int
    public var actors: [String]
}

public struct JourneyChart: Sendable {
    public var title: String?
    public var tasks: [JourneyTask]
}

public struct MindmapNode: Sendable {
    public var id: Int
    public var text: String
    public var parent: Int?
    public var depth: Int
}

public struct MindmapChart: Sendable {
    public var nodes: [MindmapNode]
}

public struct TimelineEvent: Sendable {
    public var period: String
    public var events: [String]
    public var section: String?
}

public struct TimelineChart: Sendable {
    public var title: String?
    public var entries: [TimelineEvent]
}

public struct QuadrantPoint: Sendable {
    public var label: String
    public var x: Double
    public var y: Double
}

public struct QuadrantChart: Sendable {
    public var title: String?
    public var xLeft: String
    public var xRight: String
    public var yBottom: String
    public var yTop: String
    public var points: [QuadrantPoint]
}

public struct SankeyLink: Sendable {
    public var source: String
    public var target: String
    public var value: Double
}

public struct SankeyChart: Sendable {
    public var links: [SankeyLink]
}

public struct RadarSeries: Sendable {
    public var name: String
    public var values: [Double]
}

public struct RadarChart: Sendable {
    public var title: String?
    public var axes: [String]
    public var series: [RadarSeries]
}

public struct TreemapNode: Sendable {
    public var name: String
    public var value: Double
    public var children: [TreemapNode]
}

public struct TreemapChart: Sendable {
    public var title: String?
    public var root: TreemapNode
}

public struct VennSet: Sendable {
    public var id: String
    public var label: String
}

public struct VennChart: Sendable {
    public var title: String?
    public var sets: [VennSet]
    public var intersections: [(ids: [String], label: String)]
}

public struct PacketField: Sendable {
    public var start: Int
    public var end: Int
    public var label: String
}

public struct PacketChart: Sendable {
    public var title: String?
    public var fields: [PacketField]
}

public struct BlockCell: Sendable {
    public var id: String
    public var label: String
    public var column: Int
    public var row: Int
}

public struct BlockChart: Sendable {
    public var columns: Int
    public var cells: [BlockCell]
}

public struct NamedBox: Sendable {
    public var id: String
    public var label: String
    public var detail: String
    public var group: String?
}

public struct NamedEdge: Sendable {
    public var from: String
    public var to: String
    public var label: String
}

public struct RequirementChart: Sendable {
    public var boxes: [NamedBox]
    public var edges: [NamedEdge]
}

public struct ArchitectureChart: Sendable {
    public var groups: [NamedBox]
    public var services: [NamedBox]
    public var edges: [NamedEdge]
}

public struct C4Chart: Sendable {
    public var title: String?
    public var kind: String
    public var boxes: [NamedBox]
    public var edges: [NamedEdge]
}

public struct KanbanColumn: Sendable {
    public var name: String
    public var cards: [String]
}

public struct KanbanChart: Sendable {
    public var title: String?
    public var columns: [KanbanColumn]
}

public struct UseCaseChart: Sendable {
    public var actors: [NamedBox]
    public var cases: [NamedBox]
    public var edges: [NamedEdge]
}

public struct TreeViewChart: Sendable {
    public var nodes: [MindmapNode]
}

public struct IshikawaChart: Sendable {
    public var effect: String
    public var bones: [(name: String, causes: [String])]
}

public struct CynefinChart: Sendable {
    public var title: String?
    public var domains: [(name: String, items: [String])]
}

public struct WardleyComponent: Sendable {
    public var name: String
    public var visibility: Double
    public var evolution: Double
}

public struct WardleyChart: Sendable {
    public var title: String?
    public var components: [WardleyComponent]
    public var edges: [NamedEdge]
}

public struct EventModelChart: Sendable {
    public var lanes: [(name: String, events: [String])]
}

public struct RailroadChart: Sendable {
    public var title: String?
    public var terms: [String]
}
