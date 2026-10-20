import Foundation
import CoreGraphics

public indirect enum ExtraFill: Equatable, Sendable {
    case none
    case background
    case foreground
    case muted
    case accent
    case surface
    case border
    case series(Int)
    /// Theme foreground or background, whichever is more legible on top of the given fill.
    case contrast(on: ExtraFill)
    /// The wrapped fill drawn translucently (Pele `fill-opacity`), so
    /// overlaps darken instead of covering.
    case translucent(ExtraFill)
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
    case info(InfoChart)
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

public enum GitCommitKind: Sendable {
    case normal
    case reverse
    case highlight
    case merge
    case cherryPick
}

public struct GitCommit: Sendable {
    public var id: String
    /// Text drawn under/beside the node. `nil` when the author gave no `id:`/`msg:`,
    /// so bare `commit` lines don't render the literal word "commit".
    public var label: String?
    public var tag: String?
    public var kind: GitCommitKind
    public var branch: String
    /// Global slot along the main axis (0-based, in commit-creation order).
    public var order: Int
    /// `[primaryParentId]` for a normal commit, `[primaryParentId, mergedTipId]`
    /// for a merge commit, `[]` for the very first commit on a branch with no parent.
    public var parents: [String]
    public var cherryPickSource: String?

    public init(
        id: String,
        label: String?,
        tag: String? = nil,
        kind: GitCommitKind = .normal,
        branch: String,
        order: Int,
        parents: [String],
        cherryPickSource: String? = nil
    ) {
        self.id = id
        self.label = label
        self.tag = tag
        self.kind = kind
        self.branch = branch
        self.order = order
        self.parents = parents
        self.cherryPickSource = cherryPickSource
    }
}

public struct GitBranchInfo: Sendable {
    public var name: String
    /// Explicit `branch X order: N`, else nil (falls back to declaration order).
    public var order: Int?
    /// The commit id this branch was created from (its parent's HEAD at `branch` time).
    public var forkParent: String?

    public init(name: String, order: Int? = nil, forkParent: String? = nil) {
        self.name = name
        self.order = order
        self.forkParent = forkParent
    }
}

public struct GitGraphChart: Sendable {
    public var direction: String
    public var commits: [GitCommit]
    public var branches: [GitBranchInfo]
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

public enum MindmapNodeShape: Sendable {
    case roundedRect
    case rect
    case circle
    case stadium
    case diamond
    case hexagon
}

public enum MindmapLayoutMode: Sendable {
    case treeLR
    case radial
}

public struct MindmapNode: Sendable {
    public var id: Int
    public var text: String
    public var parent: Int?
    public var depth: Int
    public var shape: MindmapNodeShape

    public init(
        id: Int,
        text: String,
        parent: Int?,
        depth: Int,
        shape: MindmapNodeShape = .roundedRect
    ) {
        self.id = id
        self.text = text
        self.parent = parent
        self.depth = depth
        self.shape = shape
    }
}

public struct MindmapChart: Sendable {
    public var nodes: [MindmapNode]
    public var layout: MindmapLayoutMode

    public init(nodes: [MindmapNode], layout: MindmapLayoutMode = .treeLR) {
        self.nodes = nodes
        self.layout = layout
    }
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
    /// From frontmatter `config.sankey.showValues` (Pele default `true`):
    /// node labels read `id value` when set.
    public var showValues: Bool = true
}

public struct RadarSeries: Sendable {
    public var name: String
    public var values: [Double]
}

public struct RadarChart: Sendable {
    public var title: String?
    public var axes: [String]
    public var series: [RadarSeries]
    public var max: Double?
    public var min: Double = 0
    public var ticks: Int = 5
    public var showLegend: Bool = true
    /// Graticule ring shape: "circle" (default) or "polygon".
    public var graticule: String = "circle"
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

/// One node of a `block-beta` tree: a plain block, a `space` gap, or a
/// `block … end` composite. Shapes use Pele's type names (`square`,
/// `round`, `circle`, `diamond`, `hexagon`, `stadium`, `subroutine`,
/// `cylinder`, `doublecircle`, `lean_right`, `lean_left`, `trapezoid`,
/// `inv_trapezoid`, `rect_left_inv_arrow`, `block_arrow`, `na`).
public struct BlockNode: Sendable {
    public var id: String
    public var label: String
    public var kind: String
    public var shape: String
    public var directions: [String]
    public var span: Int
    public var columns: Int
    public var children: [BlockNode]

    public init(
        id: String, label: String, kind: String = "block", shape: String = "na",
        directions: [String] = [], span: Int = 1, columns: Int = -1,
        children: [BlockNode] = []
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.shape = shape
        self.directions = directions
        self.span = span
        self.columns = columns
        self.children = children
    }
}

public struct BlockEdge: Sendable {
    public var start: String
    public var end: String
    public var label: String
    /// Endpoint markers (`""`, `"arrow_point"`, `"arrow_circle"`,
    /// `"arrow_cross"`, `"arrow_open"`).
    public var startMarker: String
    public var endMarker: String
    public var thick: Bool
    public var dotted: Bool

    public init(
        start: String, end: String, label: String = "",
        startMarker: String = "arrow_open", endMarker: String = "arrow_point",
        thick: Bool = false, dotted: Bool = false
    ) {
        self.start = start
        self.end = end
        self.label = label
        self.startMarker = startMarker
        self.endMarker = endMarker
        self.thick = thick
        self.dotted = dotted
    }
}

public struct BlockChart: Sendable {
    public var root: BlockNode
    public var edges: [BlockEdge]
}

public struct NamedBox: Sendable {
    public var id: String
    public var label: String
    public var detail: String
    public var group: String?
    /// Node shape hint (`"box"` default, `"junction"` for architecture junctions).
    /// Renderers that do not know a shape fall back to a box.
    public var shape: String = "box"
}

public struct NamedEdge: Sendable {
    public var from: String
    public var to: String
    public var label: String
    /// Architecture port sides (`"L"`, `"R"`, `"T"`, `"B"`); nil selects the
    /// side facing the other endpoint.
    public var fromPort: String? = nil
    public var toPort: String? = nil
    /// Architecture `{group}` modifier: the endpoint sits on the enclosing
    /// group's border instead of the node itself.
    public var fromGroup: Bool = false
    public var toGroup: Bool = false
    /// Architecture `<` / `>` arrowheads.
    public var startArrow: Bool = false
    public var endArrow: Bool = false
    /// Use-case relationship kind (`"association"`, `"include"`, `"extend"`,
    /// `"generalization"`); other renderers treat every edge as association.
    public var kind: String = "association"
    /// Use-case endpoint markers (`""`, `"arrow"`, `"circle"`, `"cross"`).
    public var startMarker: String = ""
    public var endMarker: String = ""
}

public struct UseCaseBoundary: Sendable {
    public var id: String
    public var label: String
    public var members: [String]

    public init(id: String, label: String, members: [String] = []) {
        self.id = id
        self.label = label
        self.members = members
    }
}

public struct RequirementChart: Sendable {
    public var boxes: [NamedBox]
    public var edges: [NamedEdge]
}

public struct ArchitectureAlign: Sendable {
    /// `"row"` or `"column"`.
    public var axis: String
    public var members: [String]

    public init(axis: String, members: [String]) {
        self.axis = axis
        self.members = members
    }
}

public struct ArchitectureChart: Sendable {
    public var title: String?
    public var groups: [NamedBox]
    public var services: [NamedBox]
    public var edges: [NamedEdge]
    public var alignments: [ArchitectureAlign]

    public init(
        title: String? = nil,
        groups: [NamedBox],
        services: [NamedBox],
        edges: [NamedEdge],
        alignments: [ArchitectureAlign] = []
    ) {
        self.title = title
        self.groups = groups
        self.services = services
        self.edges = edges
        self.alignments = alignments
    }
}

public struct C4Chart: Sendable {
    public var title: String?
    public var kind: String
    public var boxes: [NamedBox]
    public var edges: [NamedEdge]
}

public struct KanbanCard: Sendable {
    public var id: String
    public var label: String
    public var ticket: String?
    public var assigned: String?
    public var priority: String?

    public init(
        id: String, label: String, ticket: String? = nil,
        assigned: String? = nil, priority: String? = nil
    ) {
        self.id = id
        self.label = label
        self.ticket = ticket
        self.assigned = assigned
        self.priority = priority
    }
}

public struct KanbanColumn: Sendable {
    public var name: String
    public var cards: [KanbanCard]
}

public struct KanbanChart: Sendable {
    public var title: String?
    public var columns: [KanbanColumn]
}

public struct UseCaseChart: Sendable {
    public var actors: [NamedBox]
    public var cases: [NamedBox]
    public var edges: [NamedEdge]
    public var boundaries: [UseCaseBoundary]

    public init(
        actors: [NamedBox], cases: [NamedBox], edges: [NamedEdge],
        boundaries: [UseCaseBoundary] = []
    ) {
        self.actors = actors
        self.cases = cases
        self.edges = edges
        self.boundaries = boundaries
    }
}

/// One file-tree entry: a trailing `/` in source marks a directory.
/// Mirrors Pele's `TreeNode` (`icon()` wins, `none` hides, `highlight`
/// washes the row).
public struct TreeViewNode: Sendable {
    public var name: String
    public var isDirectory: Bool
    public var cssClass: String?
    public var icon: String?
    public var description: String?
    public var children: [TreeViewNode]

    public init(
        name: String, isDirectory: Bool = false, cssClass: String? = nil,
        icon: String? = nil, description: String? = nil,
        children: [TreeViewNode] = []
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.cssClass = cssClass
        self.icon = icon
        self.description = description
        self.children = children
    }
}

public struct TreeViewChart: Sendable {
    public var title: String?
    public var showIcons: Bool
    public var nodes: [TreeViewNode]

    public init(title: String? = nil, showIcons: Bool = false, nodes: [TreeViewNode] = []) {
        self.title = title
        self.showIcons = showIcons
        self.nodes = nodes
    }
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

public struct EventModelFrame: Sendable {
    /// Time-frame number (`01` in `tf 01 ui CartUI`).
    public var number: String
    /// Short entity tag shown on the node (`UI`, `Command`, `Event`, …).
    public var kind: String
    /// Swimlane this frame belongs to (band, or `Namespace · band`).
    public var lane: String
    /// Entity name without the namespace prefix.
    public var name: String
    /// Explicit `->>` relation targets (frame numbers).
    public var refs: [String]
    /// `rf`/`resetframe` frames break the inferred timeline relation.
    public var isReset: Bool

    public init(
        number: String, kind: String, name: String, lane: String = "",
        refs: [String] = [], isReset: Bool = false
    ) {
        self.number = number
        self.kind = kind
        self.lane = lane
        self.name = name
        self.refs = refs
        self.isReset = isReset
    }
}

public struct EventModelLane: Sendable {
    public var name: String
    public var frames: [EventModelFrame]

    public init(name: String, frames: [EventModelFrame]) {
        self.name = name
        self.frames = frames
    }
}

public struct EventModelChart: Sendable {
    public var lanes: [EventModelLane]
    /// All frames in timeline order (drives horizontal position + connectors).
    public var frames: [EventModelFrame]

    public init(lanes: [EventModelLane], frames: [EventModelFrame]) {
        self.lanes = lanes
        self.frames = frames
    }
}

/// One node of a railroad (syntax-diagram) grammar. Mirrors Pele's
/// `RailroadNode`: terminals render as pills, nonterminals as boxes,
/// specials as dashed `? … ?` boxes, sequences run left to right, choices
/// stack with bypass tracks, optionals bypass above, and repetitions loop
/// below (`max` nil means unbounded).
public indirect enum RailroadNode: Sendable {
    case terminal(String)
    case nonterminal(String)
    case special(String)
    case sequence([RailroadNode])
    case choice([RailroadNode])
    case optional(RailroadNode)
    case repetition(RailroadNode, min: Int, max: Int?)
}

public struct RailroadRule: Sendable {
    public var name: String
    public var definition: RailroadNode

    public init(name: String, definition: RailroadNode) {
        self.name = name
        self.definition = definition
    }
}

public struct RailroadChart: Sendable {
    public var title: String?
    public var notation: String
    public var rules: [RailroadRule]

    public init(title: String? = nil, notation: String = "railroad", rules: [RailroadRule] = []) {
        self.title = title
        self.notation = notation
        self.rules = rules
    }
}

/// Mermaid `info` diagram: an optional title plus the renderer's version line,
/// matching Mermaid/Pele showing their own version in the info box.
public struct InfoChart: Sendable {
    public var title: String?
}
