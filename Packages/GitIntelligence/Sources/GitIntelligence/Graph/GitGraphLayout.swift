import Foundation

public enum GitGraphAnchor: Sendable, Hashable {
    case top
    case center
    case bottom
}

public struct GitGraphSegment: Sendable, Hashable {
    public let fromLane: Int
    public let fromAnchor: GitGraphAnchor
    public let toLane: Int
    public let toAnchor: GitGraphAnchor
    public let colorIndex: Int
}

public struct GitGraphRow: Sendable, Hashable {
    public let nodeLane: Int
    public let colorIndex: Int
    public let isMerge: Bool
    public let segments: [GitGraphSegment]
    public let laneCount: Int
}

/// Incremental lane assignment for a commit graph. Feed commits in `--date-order` (children
/// before parents); later pages continue the same graph.
public struct GitGraphLayout: Sendable {
    private struct Lane: Sendable {
        var expecting: String
        var color: Int
    }

    private var lanes: [Lane?] = []
    private var nextColor = 0

    public init() {}

    public mutating func append(_ commits: [GitCommit]) -> [GitGraphRow] {
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)
        for commit in commits { rows.append(append(commit)) }
        return rows
    }

    private mutating func allocateColor() -> Int {
        defer { nextColor += 1 }
        return nextColor
    }

    private mutating func firstFreeSlot() -> Int {
        if let free = lanes.firstIndex(where: { $0 == nil }) { return free }
        lanes.append(nil)
        return lanes.count - 1
    }

    private mutating func append(_ commit: GitCommit) -> GitGraphRow {
        var segments: [GitGraphSegment] = []
        let before = lanes

        let expecting = lanes.indices.filter { lanes[$0]?.expecting == commit.hash }
        let nodeLane: Int
        let nodeColor: Int
        if let first = expecting.first, let lane = lanes[first] {
            nodeLane = first
            nodeColor = lane.color
        } else {
            nodeLane = firstFreeSlot()
            nodeColor = allocateColor()
        }

        // Lanes waiting for this commit converge on the node.
        for index in expecting {
            if let lane = before[index] {
                segments.append(GitGraphSegment(fromLane: index, fromAnchor: .top, toLane: nodeLane, toAnchor: .center, colorIndex: lane.color))
            }
            lanes[index] = nil
        }

        // Lanes not involved with this commit pass straight through.
        for index in before.indices where !expecting.contains(index) {
            if let lane = before[index] {
                segments.append(GitGraphSegment(fromLane: index, fromAnchor: .top, toLane: index, toAnchor: .bottom, colorIndex: lane.color))
            }
        }

        // Parents: the first continues in the node's lane, the rest branch off or join existing lanes.
        for (position, parent) in commit.parents.enumerated() {
            // Only a later parent joins a lane that already waits for it. The first parent always keeps
            // the node's own lane, so two lanes may wait for one commit; they converge, leftmost wins,
            // when it arrives (as `git log --graph` draws it).
            if position > 0, let existing = lanes.indices.first(where: { lanes[$0]?.expecting == parent }), let lane = lanes[existing] {
                segments.append(GitGraphSegment(fromLane: nodeLane, fromAnchor: .center, toLane: existing, toAnchor: .bottom, colorIndex: lane.color))
                continue
            }
            let target: Int
            let color: Int
            if position == 0 {
                if nodeLane >= lanes.count { lanes.append(nil) }
                target = nodeLane
                color = nodeColor
            } else {
                target = firstFreeSlot()
                color = allocateColor()
            }
            lanes[target] = Lane(expecting: parent, color: color)
            segments.append(GitGraphSegment(fromLane: nodeLane, fromAnchor: .center, toLane: target, toAnchor: .bottom, colorIndex: color))
        }

        let laneCountForRow = max(before.count, lanes.count, nodeLane + 1)
        while let last = lanes.last, last == nil { lanes.removeLast() }

        return GitGraphRow(
            nodeLane: nodeLane,
            colorIndex: nodeColor,
            isMerge: commit.parents.count > 1,
            segments: segments,
            laneCount: laneCountForRow
        )
    }
}
