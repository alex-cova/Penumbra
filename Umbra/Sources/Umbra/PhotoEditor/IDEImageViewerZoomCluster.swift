import Penumbra
import SwiftUI

/// Zoom cluster for the image toolbar: out / readout / in, then framing actions and the pixel
/// dimensions. Icon-only with text labels intact, so VoiceOver names every control.
struct IDEImageViewerZoomCluster: View {
    var controller: ImageViewerController?
    var percent: Int
    var pixelSize: CGSize

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Button("Zoom Out", systemImage: "minus.magnifyingglass", action: zoomOut)
                .help("Zoom out")

            Text("\(percent)%")
                .font(IDEAppearance.Typography.monoCaption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: Layout.percentWidth, alignment: .center)
                .accessibilityLabel("Zoom \(percent) percent")

            Button("Zoom In", systemImage: "plus.magnifyingglass", action: zoomIn)
                .help("Zoom in")

            Divider().frame(height: Layout.dividerHeight)

            Button("Actual Size", systemImage: "1.circle", action: zoomActualSize)
                .help("Actual size, 100%")

            Button("Fit", systemImage: "arrow.up.left.and.arrow.down.right", action: zoomFit)
                .help("Fit in window")

            Button("Fill", systemImage: "arrow.down.right.and.arrow.up.left", action: zoomFill)
                .help("Fill window")

            Button("Center", systemImage: "arrow.up.and.down.and.arrow.left.and.right", action: recenter)
                .help("Center the image")

            if pixelSize.width > 0 {
                Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
                    .font(IDEAppearance.Typography.monoCaption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .accessibilityLabel("Image dimensions \(Int(pixelSize.width)) by \(Int(pixelSize.height)) pixels")
            }
        }
        .labelStyle(.iconOnly)
    }

    private func zoomOut() {
        controller?.zoomOut()
    }

    private func zoomIn() {
        controller?.zoomIn()
    }

    private func zoomActualSize() {
        controller?.zoomToActualSize()
    }

    private func zoomFit() {
        controller?.zoomToFit()
    }

    private func zoomFill() {
        controller?.zoomToFill()
    }

    private func recenter() {
        controller?.recenter()
    }
}

private enum Layout {
    static let percentWidth: CGFloat = 48
    static let dividerHeight: CGFloat = 16
}
