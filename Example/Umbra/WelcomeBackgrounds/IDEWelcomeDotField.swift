import SwiftUI

/// A Canvas port of React Bits `DotField` (bulge mode, purple gradient, pointer bulge).
struct IDEWelcomeDotField: View {
    let parallax: IDEWelcomeParallax
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var viewSize: CGSize = .zero
    @State private var dots: [Dot] = []
    @State private var previousPointer: CGPoint?
    @State private var mouseSpeed: CGFloat = 0
    @State private var engagement: CGFloat = 0

    var body: some View {
        Canvas { context, size in
            guard !dots.isEmpty else { return }
            Self.draw(dots: dots, in: &context, size: size)
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            viewSize = size
            dots = Self.makeDots(in: size)
            previousPointer = nil
            mouseSpeed = 0
            engagement = 0
        }
        .task(id: isPaused) {
            guard !isPaused else { return }
            while !Task.isCancelled {
                updateMotion()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var isPaused: Bool {
        reduceMotion || controlActiveState == .inactive
    }

    private func pointerLocation() -> CGPoint {
        guard let pointer = parallax.pointer, viewSize.width > 0, viewSize.height > 0 else {
            return CGPoint(x: -9_999, y: -9_999)
        }
        return CGPoint(
            x: min(max(pointer.x, 0), viewSize.width),
            y: min(max(pointer.y, 0), viewSize.height)
        )
    }

    private func updateMotion() {
        let pointer = pointerLocation()
        if let currentPointer = parallax.pointer, let previousPointer {
            let dx = previousPointer.x - currentPointer.x
            let dy = previousPointer.y - currentPointer.y
            let dist = hypot(dx, dy)
            mouseSpeed += (dist - mouseSpeed) * 0.5
            if mouseSpeed < 0.001 { mouseSpeed = 0 }
        } else {
            mouseSpeed += (0 - mouseSpeed) * 0.5
        }
        previousPointer = parallax.pointer

        let targetEngagement = min(mouseSpeed / 5, 1)
        engagement += (targetEngagement - engagement) * 0.06
        if engagement < 0.001 { engagement = 0 }

        dots = Self.advanceDots(dots, pointer: pointer, engagement: engagement)
    }

    private struct Dot {
        let anchor: CGPoint
        var display: CGPoint
    }

    private static let dotRadius: CGFloat = 1.5
    private static let dotSpacing: CGFloat = 14
    private static let cursorRadius: CGFloat = 500
    private static let bulgeStrength: CGFloat = 67
    private static let gradientFrom = Color(red: 168 / 255, green: 85 / 255, blue: 247 / 255, opacity: 0.35)
    private static let gradientTo = Color(red: 180 / 255, green: 151 / 255, blue: 207 / 255, opacity: 0.25)

    private static func makeDots(in size: CGSize) -> [Dot] {
        guard size.width > 0, size.height > 0 else { return [] }
        let step = dotRadius + dotSpacing
        let columns = Int((size.width / step).rounded(.down))
        let rows = Int((size.height / step).rounded(.down))
        guard columns > 0, rows > 0 else { return [] }
        let padX = (size.width - CGFloat(columns) * step) / 2
        let padY = (size.height - CGFloat(rows) * step) / 2
        var dots: [Dot] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let anchor = CGPoint(
                    x: padX + CGFloat(column) * step + step / 2,
                    y: padY + CGFloat(row) * step + step / 2
                )
                dots.append(Dot(anchor: anchor, display: anchor))
            }
        }
        return dots
    }

    private static func advanceDots(_ dots: [Dot], pointer: CGPoint, engagement: CGFloat) -> [Dot] {
        let cr = cursorRadius
        let crSq = cr * cr
        return dots.map { dot in
            var display = dot.display
            let dx = pointer.x - dot.anchor.x
            let dy = pointer.y - dot.anchor.y
            let distSq = dx * dx + dy * dy

            if distSq < crSq, engagement > 0.01 {
                let dist = sqrt(distSq)
                let pushT = 1 - dist / cr
                let push = pushT * pushT * bulgeStrength * engagement
                let angle = atan2(dy, dx)
                display.x += (dot.anchor.x - cos(angle) * push - display.x) * 0.15
                display.y += (dot.anchor.y - sin(angle) * push - display.y) * 0.15
            } else {
                display.x += (dot.anchor.x - display.x) * 0.1
                display.y += (dot.anchor.y - display.y) * 0.1
            }
            return Dot(anchor: dot.anchor, display: display)
        }
    }

    private static func draw(dots: [Dot], in context: inout GraphicsContext, size: CGSize) {
        let radius = dotRadius / 2
        var path = Path()
        for dot in dots {
            path.addEllipse(in: CGRect(
                x: dot.display.x - radius,
                y: dot.display.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
        context.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [gradientFrom, gradientTo]),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: size.height)
            )
        )
    }
}
