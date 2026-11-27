import SwiftUI

/// Clips a view to the strip left of `x` (in the view's own coordinates).
private nonisolated struct LeftOfDivider: Shape {
    var x: CGFloat
    var animatableData: CGFloat {
        get { x }
        set { x = newValue }
    }
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: max(0, x - rect.minX), height: rect.height))
    }
}

/// Draggable-divider before/after: the original clipped to the left of the handle, over the edited
/// image drawn by the canvas underneath.
struct PhotoCompareSplitLayer: View {
    let original: CGImage
    /// The photo's on-screen frame — the same rect the edited image is drawn at.
    let imageRect: CGRect
    let canvasSize: CGSize
    let crisp: Bool
    @Binding var fraction: CGFloat

    private var dividerX: CGFloat { imageRect.minX + imageRect.width * min(max(fraction, 0), 1) }

    var body: some View {
        ZStack {
            Image(decorative: original, scale: 1, orientation: .up)
                .interpolation(crisp ? .none : .high)
                .resizable()
                .frame(width: max(imageRect.width, 1), height: max(imageRect.height, 1))
                .position(x: imageRect.midX, y: imageRect.midY)
                .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
                .clipShape(LeftOfDivider(x: dividerX))

            Rectangle()
                .fill(.white.opacity(0.9))
                .frame(width: 1)
                .position(x: dividerX, y: canvasSize.height / 2)

            Circle()
                .fill(.white)
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black)
                }
                .shadow(radius: 2)
                .position(x: dividerX, y: canvasSize.height / 2)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            fraction = min(1, max(0, (value.location.x - imageRect.minX) / max(imageRect.width, 1)))
                        }
                )
                .accessibilityLabel("Before / after divider")

            label("Before", x: imageRect.minX + 6, alignment: .leading)
                .opacity(fraction > 0.08 ? 1 : 0)
            label("After", x: imageRect.maxX - 6, alignment: .trailing)
                .opacity(fraction < 0.92 ? 1 : 0)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(true)
    }

    private func label(_ text: String, x: CGFloat, alignment: HorizontalAlignment) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.5), in: .capsule)
            .position(x: alignment == .leading ? x + 24 : x - 22, y: max(imageRect.minY + 14, 14))
            .allowsHitTesting(false)
    }
}

/// Original and edited fitted into the two halves of the canvas.
struct PhotoCompareSideBySideLayer: View {
    let original: CGImage
    let edited: CGImage
    let imagePixelSize: CGSize
    let canvasSize: CGSize
    let crisp: Bool

    var body: some View {
        let half = CGSize(width: canvasSize.width / 2, height: canvasSize.height)
        let vp = PhotoViewport.fitting(imagePixelSize: imagePixelSize, in: half)
        let rect = vp.imageRect(imagePixelSize: imagePixelSize, in: half)
        HStack(spacing: 0) {
            pane(original, rect: rect, label: "Before")
                .frame(width: half.width, height: half.height)
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1)
            pane(edited, rect: rect, label: "After")
                .frame(width: half.width, height: half.height)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
    }

    private func pane(_ image: CGImage, rect: CGRect, label: String) -> some View {
        ZStack(alignment: .top) {
            Image(decorative: image, scale: 1, orientation: .up)
                .interpolation(crisp ? .none : .high)
                .resizable()
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .position(x: rect.midX, y: rect.midY)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.5), in: .capsule)
                .padding(.top, 6)
        }
    }
}
