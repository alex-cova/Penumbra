import SwiftUI

/// A glint that travels around the composer's edge while the chat is empty.
/// An angular highlight arc spins behind a static border mask, so the field reads
/// reflective without redrawing its fill. Mounted only while empty, so sending a
/// message stops it; never mounted when animation is off.
struct IDEAIMirrorBorder: View {
    @State private var spins = false

    var body: some View {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.55), location: 0.1),
                .init(color: .clear, location: 0.22),
                .init(color: .clear, location: 1),
            ]),
            center: .center
        )
        .rotationEffect(.degrees(spins ? 360 : 0))
        .mask {
            RoundedRectangle(cornerRadius: IDEAppearance.Radius.panel, style: .continuous)
                .strokeBorder(lineWidth: 1.5)
        }
        .animation(.linear(duration: 2.8).repeatForever(autoreverses: false), value: spins)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { spins = true }
    }
}
