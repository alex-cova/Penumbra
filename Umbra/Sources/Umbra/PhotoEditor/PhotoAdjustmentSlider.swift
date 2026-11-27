import AppKit
import SwiftUI

/// Lightroom-style parameter slider: name and an editable numeric field on one row, a thin track
/// beneath with a centre detent, bidirectional fill, and an optional white-balance gradient behind
/// the track. Behaviour matches the original control — snap within a few units of the detent with a
/// haptic tick, double-click to reset, `accessibilityAdjustableAction` in steps of 5.
struct PhotoAdjustmentSlider: View {
    let value: Double
    let parameterName: LocalizedStringResource
    var lowerBound: Double = -100
    var upperBound: Double = 100
    var detent: Double? = 0
    var gradient: PhotoSliderGradient?
    let onChanged: (Double) -> Void
    let onEnded: () -> Void

    private var tint: Color { PhotoStudio.accent }

    @State private var trackWidth: CGFloat = 0
    @State private var didSnap = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: PhotoStudio.Spacing.xs) {
                Text(parameterName)
                    .font(PhotoStudio.Typography.caption)
                    .foregroundStyle(PhotoStudio.Photo.label)
                Spacer(minLength: 0)
                PhotoInspectorValueField(
                    value: value,
                    range: lowerBound...upperBound,
                    showsSign: lowerBound < 0,
                    onCommit: { committed in
                        onChanged(committed)
                        onEnded()
                    }
                )
                PhotoInspectorResetButton(isEnabled: isOffDetent, action: resetToDetent)
            }

            track
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(parameterName))
        .accessibilityValue("\(Int(value.rounded()))")
        .accessibilityAdjustableAction(adjust)
    }

    private var track: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(PhotoStudio.Photo.track)
                .frame(height: 3)
                .overlay {
                    if let gradient {
                        Capsule()
                            .fill(gradientFill(gradient))
                            .frame(height: 3)
                            .opacity(0.5)
                    }
                }

            fill

            if let detent, detent > lowerBound, detent < upperBound {
                Rectangle()
                    .fill(PhotoStudio.Photo.value.opacity(0.5))
                    .frame(width: 1, height: 7)
                    .offset(x: max(0, position(for: detent) - 0.5))
            }

            Circle()
                .fill(PhotoStudio.Photo.value)
                .frame(width: 11, height: 11)
                .overlay {
                    Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5)
                }
                .offset(x: max(0, thumbX - 5.5))
                .shadow(color: Color.black.opacity(0.4), radius: 1, y: 1)
        }
        .frame(height: 20)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { trackWidth = $0 }
        .gesture(drag)
        .onTapGesture(count: 2, perform: resetToDetent)
    }

    @ViewBuilder
    private var fill: some View {
        let anchor = min(max(lowerBound, detent ?? lowerBound), upperBound)
        let anchorX = position(for: anchor)
        Capsule()
            .fill(tint)
            .frame(width: max(2, abs(thumbX - anchorX)), height: 3)
            .offset(x: min(thumbX, anchorX))
    }

    private var isOffDetent: Bool {
        abs(value - (detent ?? 0)) > 0.5
    }

    private func gradientFill(_ gradient: PhotoSliderGradient) -> LinearGradient {
        let stops: [Color]
        switch gradient {
        case .temperature:
            stops = [Color(red: 0.30, green: 0.55, blue: 1.0), Color(white: 0.6), Color(red: 1.0, green: 0.78, blue: 0.25)]
        case .tint:
            stops = [Color(red: 0.35, green: 0.85, blue: 0.4), Color(white: 0.6), Color(red: 0.95, green: 0.35, blue: 0.85)]
        }
        return LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
    }

    private func position(for raw: Double) -> CGFloat {
        guard trackWidth > 0 else { return 0 }
        let span = max(upperBound - lowerBound, 0.0001)
        return CGFloat((raw - lowerBound) / span) * trackWidth
    }

    private var thumbX: CGFloat { position(for: value) }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard trackWidth > 0 else { return }
                let unit = min(1, max(0, gesture.location.x / trackWidth))
                var next = lowerBound + unit * (upperBound - lowerBound)
                if let detent, abs(next - detent) < 4 {
                    next = detent
                    if !didSnap {
                        didSnap = true
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                } else {
                    didSnap = false
                }
                onChanged(next)
            }
            .onEnded { _ in
                didSnap = false
                onEnded()
            }
    }

    private func resetToDetent() {
        onChanged(detent ?? 0)
        onEnded()
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        let step: Double = 5
        switch direction {
        case .increment: onChanged(min(upperBound, value + step))
        case .decrement: onChanged(max(lowerBound, value - step))
        @unknown default: break
        }
        onEnded()
    }
}
