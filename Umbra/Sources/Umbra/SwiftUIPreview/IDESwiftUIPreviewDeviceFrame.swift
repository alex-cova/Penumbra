import SwiftUI

/// A phone's body drawn around the preview's frame: the bezel, the corner radius of the screen and
/// its notch or Dynamic Island. It is only a drawing; the frame inside is what the host rendered.
/// Everything is in points of the device times `scale`, so it follows the zoom.
struct IDESwiftUIPreviewDeviceFrame<Content: View>: View {
    let device: IDESwiftUIPreviewDevice
    let scale: Double
    @ViewBuilder let content: () -> Content

    var body: some View {
        let s = CGFloat(scale)
        let body = RoundedRectangle(cornerRadius: device.bodyCornerRadius * s, style: .continuous)
        content()
            .clipShape(RoundedRectangle(cornerRadius: device.cornerRadius * s, style: .continuous))
            .overlay(alignment: .top) { cutout(s) }
            .padding(EdgeInsets(
                top: device.bezelTop * s, leading: device.bezelSide * s,
                bottom: device.bezelBottom * s, trailing: device.bezelSide * s
            ))
            .background {
                // The shadow belongs to the body alone: on the whole view it would fall on the content.
                // A metal rim around a black bezel: the body must read on a dark panel and a light one.
                body
                    .fill(Color(white: 0.03))
                    .shadow(color: .black.opacity(0.35), radius: 14 * s, y: 6 * s)
                    .overlay {
                        body.strokeBorder(
                            LinearGradient(
                                colors: [Color(white: 0.72), Color(white: 0.38), Color(white: 0.6)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: max(2, 3.5 * s)
                        )
                    }
            }
            .overlay(alignment: .bottom) {
                if device.cutout == .homeButton {
                    // The home button sits in the middle of the lower bezel.
                    Circle()
                        .strokeBorder(Color.white.opacity(0.28), lineWidth: max(1, 1.5 * s))
                        .frame(width: 46 * s, height: 46 * s)
                        .padding(.bottom, (device.bezelBottom - 46) / 2 * s)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private func cutout(_ s: CGFloat) -> some View {
        switch device.cutout {
        case .dynamicIsland:
            Capsule()
                .fill(Color.black)
                .frame(width: 126 * s, height: 37 * s)
                .padding(.top, 11 * s)
                .allowsHitTesting(false)
        case .notch:
            UnevenRoundedRectangle(bottomLeadingRadius: 18 * s, bottomTrailingRadius: 18 * s)
                .fill(Color.black)
                .frame(width: 164 * s, height: 32 * s)
                .allowsHitTesting(false)
        case .homeButton:
            EmptyView()
        }
    }
}
