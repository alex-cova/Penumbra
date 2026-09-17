import Foundation

/// Recursive layout of editor panes and split containers.
public enum EditorLayout: Equatable, Sendable {
    case pane(EditorPane)
    case vertical(EditorSplitData)
    case horizontal(EditorSplitData)

    public func flattenedPanes() -> [EditorPane] {
        switch self {
        case .pane(let pane):
            return [pane]
        case .vertical(let data), .horizontal(let data):
            return data.flattenedPanes()
        }
    }

    public func findPane(id: UUID) -> EditorPane? {
        switch self {
        case .pane(let pane):
            return pane.id == id ? pane : nil
        case .vertical(let data), .horizontal(let data):
            for child in data.children {
                if let match = child.findPane(id: id) {
                    return match
                }
            }
            return nil
        }
    }

    public func findSomePane(except excludedID: UUID? = nil) -> EditorPane? {
        switch self {
        case .pane(let pane):
            if pane.id != excludedID {
                return pane
            }
            return nil
        case .vertical(let data), .horizontal(let data):
            for child in data.children {
                if let match = child.findSomePane(except: excludedID) {
                    return match
                }
            }
            return nil
        }
    }

    public mutating func splitPane(_ paneID: UUID, edge: EditorSplitEdge, newPane: EditorPane) {
        switch self {
        case .pane(let pane) where pane.id == paneID:
            let existing = EditorLayout.pane(pane)
            switch edge {
            case .leading, .top:
                self = .horizontal(EditorSplitData(axis: .horizontal, children: [.pane(newPane), existing]))
            case .trailing, .bottom:
                self = .horizontal(EditorSplitData(axis: .horizontal, children: [existing, .pane(newPane)]))
            }
        case .vertical(let data), .horizontal(let data):
            for index in data.children.indices {
                if case .pane(let pane) = data.children[index], pane.id == paneID {
                    data.split(edge, at: index, new: newPane)
                    return
                }
                var child = data.children[index]
                if child.findPane(id: paneID) != nil {
                    child.splitPane(paneID, edge: edge, newPane: newPane)
                    data.children[index] = child
                    return
                }
            }
        case .pane:
            break
        }
    }

    public mutating func closePane(_ paneID: UUID) {
        switch self {
        case .pane:
            break
        case .vertical(let data), .horizontal(let data):
            data.closePane(with: paneID)
            for index in data.children.indices {
                data.children[index].closePane(paneID)
            }
        }
    }

    public mutating func flatten() {
        switch self {
        case .pane:
            break
        case .horizontal(let data), .vertical(let data):
            if data.children.count == 1 {
                self = data.children[0]
            } else {
                data.flatten()
            }
        }
    }

    public static func == (lhs: EditorLayout, rhs: EditorLayout) -> Bool {
        switch (lhs, rhs) {
        case let (.pane(lhsPane), .pane(rhsPane)):
            return lhsPane.id == rhsPane.id
        case let (.vertical(lhs), .vertical(rhs)):
            return lhs.axis == rhs.axis && lhs.children == rhs.children
        case let (.horizontal(lhs), .horizontal(rhs)):
            return lhs.axis == rhs.axis && lhs.children == rhs.children
        default:
            return false
        }
    }
}
