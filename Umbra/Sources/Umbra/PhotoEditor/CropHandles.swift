import SwiftUI

/// The eight resize handles on a crop or redaction rectangle. Lifted out of `PhotoCanvasView` so the
/// crop overlay and the redaction overlay share one set of knobs and hit targets.
enum CropHandle: String, CaseIterable, Identifiable {
    case top, left, right, bottom, topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: true
        case .top, .bottom, .left, .right: false
        }
    }

    var isHorizontalEdge: Bool {
        self == .top || self == .bottom
    }

    /// The opposite corner/edge that stays put while this handle is dragged — the fixed point an
    /// aspect-locked resize pivots around.
    var anchor: CropAnchor {
        switch self {
        case .topLeft: .bottomRight
        case .topRight: .bottomLeft
        case .bottomLeft: .topRight
        case .bottomRight: .topLeft
        case .top: .bottom
        case .bottom: .top
        case .left: .right
        case .right: .left
        }
    }

    var accessibilityLabel: LocalizedStringResource {
        switch self {
        case .topLeft: "Top left crop handle"
        case .top: "Top crop handle"
        case .topRight: "Top right crop handle"
        case .left: "Left crop handle"
        case .right: "Right crop handle"
        case .bottomLeft: "Bottom left crop handle"
        case .bottom: "Bottom crop handle"
        case .bottomRight: "Bottom right crop handle"
        }
    }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}

/// The fixed reference point for an aspect-locked crop resize, in normalized crop space.
nonisolated enum CropAnchor: Sendable {
    case topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right

    /// The point of `rect` this anchor names.
    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        }
    }
}

struct CropHandleKnob: View {
    let handle: CropHandle

    var body: some View {
        Group {
            if handle.isCorner {
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .shadow(radius: 1)
            } else {
                Capsule()
                    .fill(Color.white)
                    .frame(
                        width: handle.isHorizontalEdge ? 22 : 5,
                        height: handle.isHorizontalEdge ? 5 : 22
                    )
                    .shadow(radius: 1)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(handle.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}
