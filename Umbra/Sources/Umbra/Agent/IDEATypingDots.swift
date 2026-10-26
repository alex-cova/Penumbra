import SwiftUI

/// Three dots that take turns pulsing while the model is working, as in a chat app's typing
/// indicator. Shown in the status row next to what the run is doing; the streaming text itself
/// takes over once the model starts answering. Static dots when Reduce Motion is on.
struct IDEATypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let dotCount = 3
    private static let dotSize: CGFloat = 6

    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<Self.dotCount, id: \.self) { index in
                Circle()
                    .fill(IDEAppearance.ColorToken.muted)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .opacity(animating ? 1 : 0.35)
                    .scaleEffect(animating ? 1.25 : 0.85)
                    .animation(pulse(delay: Double(index) * 0.15), value: animating)
            }
        }
        .onAppear { animating = !reduceMotion }
        .accessibilityLabel("Model is working")
    }

    /// Each dot runs the same pulse with its own delay, so the lit dot travels around the three.
    /// `nil` without motion: the dots sit still at their resting values.
    private func pulse(delay: Double) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(delay)
    }
}
