import SwiftUI

/// Canvas overlay for the redaction mode: draw new boxes on empty space, click to select, drag to
/// move, corner-drag to resize. Coordinates are normalized to `imageRect` (the oriented, uncropped
/// photo frame) so they match `RedactionRegion.rect`.
struct RedactOverlay: View {
    let imageRect: CGRect
    let regions: [RedactionRegion]
    let selectedID: UUID?
    var tint: Color
    var onDrawEnded: (CGRect) -> Void
    var onSelect: (UUID?) -> Void
    var onChange: (UUID, CGRect) -> Void
    var onChangeEnded: () -> Void

    @State private var draft: CGRect?
    @State private var dragOriginRect: CGRect?

    private let corners: [CropHandle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .gesture(newBoxDrag)
                .onTapGesture { onSelect(nil) }

            ForEach(regions) { region in
                boxView(region)
            }

            if let draft {
                Rectangle()
                    .strokeBorder(.white, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .background(Color.black.opacity(0.25))
                    .frame(width: draft.width, height: draft.height)
                    .position(x: draft.midX, y: draft.midY)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Boxes

    @ViewBuilder
    private func boxView(_ region: RedactionRegion) -> some View {
        let rect = viewRect(region.rect)
        let isSelected = region.id == selectedID
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.001))
                .overlay {
                    Rectangle().strokeBorder(
                        isSelected ? tint : Color.white.opacity(0.85),
                        lineWidth: isSelected ? 2 : 1
                    )
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .highPriorityGesture(moveDrag(region))
                .onTapGesture { onSelect(region.id) }
                .accessibilityLabel("\(String(localized: region.style.displayName)) region")
                .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isSelected {
                ForEach(corners) { handle in
                    CropHandleKnob(handle: handle)
                        .position(handle.point(in: rect))
                        .highPriorityGesture(resizeDrag(region, handle: handle))
                }
            }
        }
    }

    private func moveDrag(_ region: RedactionRegion) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragOriginRect == nil {
                    dragOriginRect = region.rect
                    onSelect(region.id)
                }
                guard let origin = dragOriginRect else { return }
                let dx = value.translation.width / max(imageRect.width, 1)
                let dy = value.translation.height / max(imageRect.height, 1)
                var next = origin.offsetBy(dx: dx, dy: dy)
                next.origin.x = min(max(0, next.origin.x), 1 - next.width)
                next.origin.y = min(max(0, next.origin.y), 1 - next.height)
                onChange(region.id, next)
            }
            .onEnded { _ in
                dragOriginRect = nil
                onChangeEnded()
            }
    }

    private func resizeDrag(_ region: RedactionRegion, handle: CropHandle) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragOriginRect == nil { dragOriginRect = region.rect }
                guard let origin = dragOriginRect else { return }
                let dx = value.translation.width / max(imageRect.width, 1)
                let dy = value.translation.height / max(imageRect.height, 1)
                var minX = origin.minX, minY = origin.minY
                var maxX = origin.maxX, maxY = origin.maxY
                switch handle {
                case .topLeft: minX += dx; minY += dy
                case .topRight: maxX += dx; minY += dy
                case .bottomLeft: minX += dx; maxY += dy
                case .bottomRight: maxX += dx; maxY += dy
                default: break
                }
                var next = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).standardized
                if next.width < 0.02 { next.size.width = 0.02 }
                if next.height < 0.02 { next.size.height = 0.02 }
                next.origin.x = min(max(0, next.origin.x), 1 - next.width)
                next.origin.y = min(max(0, next.origin.y), 1 - next.height)
                onChange(region.id, next)
            }
            .onEnded { _ in
                dragOriginRect = nil
                onChangeEnded()
            }
    }

    // MARK: - New box

    private var newBoxDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let clamped = imageRect.intersection(CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.translation.width),
                    height: abs(value.translation.height)
                ))
                draft = clamped.isNull ? nil : clamped
            }
            .onEnded { _ in
                defer { draft = nil }
                guard let draft, draft.width > 6, draft.height > 6 else { return }
                onDrawEnded(normalized(draft))
            }
    }

    // MARK: - Mapping

    private func viewRect(_ unit: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + unit.minX * imageRect.width,
            y: imageRect.minY + unit.minY * imageRect.height,
            width: unit.width * imageRect.width,
            height: unit.height * imageRect.height
        )
    }

    private func normalized(_ rect: CGRect) -> CGRect {
        guard imageRect.width > 0, imageRect.height > 0 else { return .zero }
        return CGRect(
            x: (rect.minX - imageRect.minX) / imageRect.width,
            y: (rect.minY - imageRect.minY) / imageRect.height,
            width: rect.width / imageRect.width,
            height: rect.height / imageRect.height
        ).standardized
    }
}
