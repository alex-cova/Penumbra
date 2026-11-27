import SwiftUI

struct CurvesPane: View {
    @Bindable var session: PhotoEditorSession
    @AppStorage("photoEditor.module.tonecurve") private var isExpanded = false

    var body: some View {
        PhotoInspectorModule(
            title: "Tone Curve",
            isExpanded: $isExpanded,
            trailing: {
                PhotoInspectorResetButton(
                    isEnabled: !session.adjustments.toneCurve.isIdentity,
                    action: resetAllCurves
                )
            }
        ) {
            HStack(spacing: PhotoStudio.Spacing.xs) {
                ForEach(ToneCurveChannel.allCases) { channel in
                    PhotoInspectorChip(
                        title: channel.shortLabel,
                        isSelected: session.activeCurveChannel == channel,
                        tint: channelTint(channel),
                        action: { select(channel) }
                    )
                    .accessibilityLabel(Text(channel.displayName))
                }
            }

            ToneCurveGraph(
                values: session.adjustments.toneCurve[session.activeCurveChannel],
                channel: session.activeCurveChannel
            ) { values in
                session.mutate { adj in
                    adj.toneCurve[session.activeCurveChannel] = values
                }
            } onEnded: {
                session.commit()
            }
        }
    }

    private func select(_ channel: ToneCurveChannel) {
        session.activeCurveChannel = channel
    }

    private func resetAllCurves() {
        session.mutate { $0.toneCurve = ToneCurve() }
        session.commit()
    }

    private func channelTint(_ channel: ToneCurveChannel) -> Color {
        switch channel {
        case .rgb: PhotoStudio.accent
        case .red: Color.red
        case .green: Color.green
        case .blue: Color.blue
        }
    }
}

struct ToneCurveGraph: View {
    let values: [Double]
    let channel: ToneCurveChannel
    let onChanged: ([Double]) -> Void
    let onEnded: () -> Void

    @State private var size: CGSize = .zero
    @State private var draggingIndex: Int?

    var body: some View {
        Canvas { context, canvasSize in
            drawGrid(context: context, size: canvasSize)
            drawCurve(context: context, size: canvasSize)
            drawHandles(context: context, size: canvasSize)
        }
        .frame(height: 148)
        .background(PhotoStudio.Photo.panelDeep, in: .rect(cornerRadius: PhotoStudio.Radius.xs))
        .overlay {
            RoundedRectangle(cornerRadius: PhotoStudio.Radius.xs)
                .strokeBorder(PhotoStudio.Photo.hairline, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size = $0 }
        .gesture(drag)
        .onTapGesture(count: 2) {
            onChanged(ToneCurve.identityYs)
            onEnded()
        }
        .accessibilityLabel("Tone curve")
        .accessibilityValue(accessibilitySummary)
        .accessibilityAdjustableAction { direction in
            var next = ToneCurve.clamped(values)
            let delta: Double = direction == .increment ? 0.05 : -0.05
            next[2] = min(1, max(0, next[2] + delta))
            onChanged(next)
            onEnded()
        }
    }

    private var handleColor: Color {
        switch channel {
        case .rgb: PhotoStudio.Photo.value
        case .red: Color.red
        case .green: Color.green
        case .blue: Color.blue
        }
    }

    private var accessibilitySummary: String {
        let mid = Int(((values[safe: 2] ?? 0.5) * 100).rounded())
        return "Midtone \(mid) percent"
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                let index = draggingIndex ?? nearestIndex(to: value.startLocation)
                draggingIndex = index
                let y = 1 - min(1, max(0, value.location.y / size.height))
                var next = ToneCurve.clamped(values)
                next[index] = y
                onChanged(next)
            }
            .onEnded { _ in
                draggingIndex = nil
                onEnded()
            }
    }

    private func nearestIndex(to location: CGPoint) -> Int {
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for index in 0..<5 {
            let handle = point(at: index, in: size)
            let distance = hypot(handle.x - location.x, handle.y - location.y)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    private func point(at index: Int, in size: CGSize) -> CGPoint {
        let x = ToneCurve.sampleXs[index] * size.width
        let y = (1 - (values[safe: index] ?? ToneCurve.identityYs[index])) * size.height
        return CGPoint(x: x, y: y)
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        var grid = Path()
        for i in 1...3 {
            let t = CGFloat(i) / 4
            grid.move(to: CGPoint(x: t * size.width, y: 0))
            grid.addLine(to: CGPoint(x: t * size.width, y: size.height))
            grid.move(to: CGPoint(x: 0, y: t * size.height))
            grid.addLine(to: CGPoint(x: size.width, y: t * size.height))
        }
        context.stroke(grid, with: .color(PhotoStudio.Photo.hairline), lineWidth: 1)

        var diagonal = Path()
        diagonal.move(to: CGPoint(x: 0, y: size.height))
        diagonal.addLine(to: CGPoint(x: size.width, y: 0))
        context.stroke(
            diagonal,
            with: .color(PhotoStudio.Photo.label.opacity(0.5)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
        )
    }

    private func drawCurve(context: GraphicsContext, size: CGSize) {
        var path = Path()
        let samples = 32
        for i in 0...samples {
            let x = Double(i) / Double(samples)
            let y = PhotoColorCube.interpolate(
                xs: ToneCurve.sampleXs,
                ys: ToneCurve.clamped(values),
                x: x
            )
            let point = CGPoint(x: x * size.width, y: (1 - y) * size.height)
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        context.stroke(path, with: .color(handleColor.opacity(0.95)), lineWidth: 1.5)
    }

    private func drawHandles(context: GraphicsContext, size: CGSize) {
        for index in 0..<5 {
            let center = point(at: index, in: size)
            let rect = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: rect), with: .color(handleColor))
            context.stroke(Path(ellipseIn: rect), with: .color(Color.black.opacity(0.35)), lineWidth: 1)
        }
    }
}

private extension Array where Element == Double {
    subscript(safe index: Int) -> Double? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
