import SwiftUI

struct IDEWelcomeView: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var parallax = IDEWelcomeParallax()

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: IDEAppearance.Spacing.xxl)

            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xl) {
                IDEWelcomeBrandHeader()
                IDEWelcomeActionList(
                    openFile: workspace.openFile,
                    openFolder: workspace.openFolder,
                    newFile: workspace.newFile
                )
                if !workspace.recentProjectURLs.isEmpty {
                    IDEWelcomeRecentProjectsSection(
                        urls: Array(workspace.recentProjectURLs.prefix(8)),
                        onOpen: workspace.openRecentProject
                    )
                }
                if !workspace.recentFileURLs.isEmpty {
                    IDEWelcomeRecentFilesSection(
                        urls: Array(workspace.recentFileURLs.prefix(8)),
                        onOpen: workspace.openRecentFile
                    )
                }
                IDEWelcomeShortcutsGrid()
            }
            .frame(maxWidth: IDEAppearance.Spacing.welcomeMaxWidth, alignment: .leading)

            Spacer(minLength: IDEAppearance.Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): parallax.pointer = location
            case .ended: parallax.pointer = nil
            }
        }
        .background {
            IDEWelcomeStarfield(parallax: parallax)
                .background(IDEAppearance.ColorToken.editor)
        }
    }
}

private struct IDEWelcomeBrandHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Label {
                Text("Umbra")
                    .font(IDEAppearance.Typography.brandTitle)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
            } icon: {
                Image(systemName: "text.alignleft")
                    .font(.title2)
                    .foregroundStyle(IDEAppearance.ColorToken.accent)
            }
            .labelStyle(.titleAndIcon)

            Text("A lightweight code editor for macOS")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }
}

private struct IDEWelcomeActionList: View {
    let openFile: () -> Void
    let openFolder: () -> Void
    let newFile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            IDEWelcomeActionRow(title: "Open File…", systemImage: "doc", shortcut: "⌘O", action: openFile)
            IDEWelcomeActionRow(title: "Open Folder…", systemImage: "folder", shortcut: "⌘⇧O", action: openFolder)
            IDEWelcomeActionRow(title: "New File", systemImage: "doc.badge.plus", shortcut: "⌘N", action: newFile)
        }
    }
}

private struct IDEWelcomeActionRow: View {
    let title: String
    let systemImage: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: IDEAppearance.Spacing.md) {
                Label(title, systemImage: systemImage)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                Spacer(minLength: 0)
                Text(shortcut)
                    .font(IDEAppearance.Typography.monoCaption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IDEAppearance.ColorToken.tabActive)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Keyboard shortcut \(shortcut)")
    }
}

private struct IDEWelcomeRecentProjectsSection: View {
    let urls: [URL]
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text("Recent Projects")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(urls, id: \.path) { url in
                    Button(url.lastPathComponent, systemImage: "folder", action: { onOpen(url) })
                        .buttonStyle(IDEWelcomeLinkButtonStyle())
                        .help(url.path)
                }
            }
        }
    }
}

private struct IDEWelcomeRecentFilesSection: View {
    let urls: [URL]
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text("Recent")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(urls, id: \.path) { url in
                    Button(url.lastPathComponent, systemImage: "doc.text", action: { onOpen(url) })
                        .buttonStyle(IDEWelcomeLinkButtonStyle())
                        .help(url.path)
                }
            }
        }
    }
}

private struct IDEWelcomeShortcutsGrid: View {
    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text("Shortcuts")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .textCase(.uppercase)

            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading,
                spacing: IDEAppearance.Spacing.xs
            ) {
                IDEWelcomeShortcutCell(keys: "⌘P", action: "Go to File")
                IDEWelcomeShortcutCell(keys: "⌘⇧P", action: "Command Palette")
                IDEWelcomeShortcutCell(keys: "⌘L", action: "Go to Line")
                IDEWelcomeShortcutCell(keys: "⌘R", action: "Go to Symbol")
                IDEWelcomeShortcutCell(keys: "⌘F", action: "Find")
                IDEWelcomeShortcutCell(keys: "⌘⇧F", action: "Find in Files")
            }
        }
    }
}

private struct IDEWelcomeShortcutCell: View {
    let keys: String
    let action: String

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Text(keys)
                .font(IDEAppearance.Typography.monoCaption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 56, alignment: .trailing)
            Text(action)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }
}

private struct IDEWelcomeLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(
                configuration.isPressed
                    ? IDEAppearance.ColorToken.accent
                    : IDEAppearance.ColorToken.foreground
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
    }
}

/// Pointer position for the starfield's parallax. A plain reference rather than
/// observed state: the starfield redraws every frame anyway, so a mouse move shouldn't
/// invalidate the welcome view's body.
@MainActor
private final class IDEWelcomeParallax {
    /// Pointer location in the welcome view, `nil` once it leaves.
    var pointer: CGPoint?
    /// Eased pointer position, -1...1 per axis from the center.
    private(set) var current = CGVector.zero
    private var lastTime: Double?

    /// Moves `current` toward the pointer, frame-rate independently.
    func advance(to time: Double, in size: CGSize) -> CGVector {
        var target = CGVector.zero
        if let pointer, size.width > 0, size.height > 0 {
            target.dx = min(max(pointer.x / size.width * 2 - 1, -1), 1)
            target.dy = min(max(pointer.y / size.height * 2 - 1, -1), 1)
        }
        let dt = lastTime.map { min(max(time - $0, 0), 0.1) } ?? 0
        lastTime = time
        let blend = 1 - exp(-dt * 4)
        current.dx += (target.dx - current.dx) * blend
        current.dy += (target.dy - current.dy) * blend
        return current
    }
}

/// Twinkling, slowly drifting starfield behind the welcome page. A Canvas port of a
/// three-layer fragment shader (small dots, medium and big four-point sparkles), with
/// stars laid out once per size instead of hashed per pixel, so a frame costs a few
/// hundred fills. Layers shift away from the pointer by depth (parallax). Holds still
/// under Reduce Motion and while the window isn't active.
private struct IDEWelcomeStarfield: View {
    let parallax: IDEWelcomeParallax
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var stars: [Star] = []

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { timeline in
            Canvas { context, size in
                let time = isPaused ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 3600)
                let tilt = isPaused ? .zero : parallax.advance(to: time, in: size)
                Self.draw(stars, in: &context, size: size, time: time, tilt: tilt)
            }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            stars = Self.makeStars(in: size)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var isPaused: Bool {
        reduceMotion || controlActiveState == .inactive
    }

    struct Star {
        enum Kind { case small, medium, big }

        let kind: Kind
        let position: CGPoint
        /// Random in 0...1; drives brightness and twinkle phase.
        let seed: Double
    }

    private static let drift = CGVector(dx: 10, dy: 3.5)
    /// Margin wrapped stars travel through, so big sparkles don't pop at the edges.
    private static let wrapMargin: CGFloat = 40

    private static func rand(_ x: Double, _ y: Double) -> Double {
        let value = sin(x * 12.9898 + y * 78.233) * 43758.5453123
        return value - value.rounded(.down)
    }

    static func makeStars(in size: CGSize) -> [Star] {
        guard size.width > 0, size.height > 0 else { return [] }
        var stars: [Star] = []
        func scatter(_ kind: Star.Kind, cell: CGFloat, amount: Double) {
            let columns = Int((size.width / cell).rounded(.up))
            let rows = Int((size.height / cell).rounded(.up))
            for row in 0..<rows {
                for column in 0..<columns {
                    let value = rand(Double(column), Double(row) + cell)
                    guard value > 1 - amount else { continue }
                    let seed = (value - (1 - amount)) / amount
                    let jitter = CGPoint(
                        x: rand(Double(row), Double(column) * 3.1) * 0.6 + 0.2,
                        y: rand(Double(column) * 7.3, Double(row)) * 0.6 + 0.2
                    )
                    stars.append(Star(
                        kind: kind,
                        position: CGPoint(x: (CGFloat(column) + jitter.x) * cell, y: (CGFloat(row) + jitter.y) * cell),
                        seed: seed
                    ))
                }
            }
        }
        scatter(.small, cell: 9, amount: 0.09)
        scatter(.medium, cell: 20, amount: 0.01)
        scatter(.big, cell: 100, amount: 0.02)
        return stars
    }

    static func draw(_ stars: [Star], in context: inout GraphicsContext, size: CGSize, time: Double, tilt: CGVector) {
        context.blendMode = .plusLighter
        let width = size.width + wrapMargin * 2
        let height = size.height + wrapMargin * 2
        for star in stars {
            // Nearer (bigger) layers drift faster, like the shader's per-layer slow factors.
            let slow: Double
            let depth: CGFloat
            switch star.kind {
            case .small: slow = 8; depth = 4
            case .medium: slow = 6; depth = 10
            case .big: slow = 2; depth = 24
            }
            let x = (star.position.x + wrapMargin + drift.dx * time / slow - tilt.dx * depth).truncatingRemainder(dividingBy: width)
            let y = (star.position.y + wrapMargin + drift.dy * time / slow - tilt.dy * depth).truncatingRemainder(dividingBy: height)
            let center = CGPoint(x: x - wrapMargin, y: y - wrapMargin)

            switch star.kind {
            case .small:
                let brightness = star.seed * (0.85 * sin(time * star.seed * 5 + 720 * star.seed) + 0.95)
                let opacity = min(max(brightness, 0), 1) * 0.8
                guard opacity > 0.02 else { continue }
                let side: CGFloat = star.seed > 0.85 ? 1.5 : 1
                context.fill(
                    Path(CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)),
                    with: .color(.white.opacity(opacity))
                )
            case .medium, .big:
                let twinkle = 0.9 + 0.2 * sin(time * 8 + star.seed * 45)
                let radius: CGFloat = star.kind == .big ? 14 : 6
                drawSparkle(in: &context, at: center, radius: radius * twinkle, intensity: twinkle * twinkle - 0.25)
            }
        }
    }

    /// A four-point star with concave sides, the shape the shader's `1 / (|dx| * |dy|)`
    /// falloff draws, plus a small glowing core.
    private static func drawSparkle(in context: inout GraphicsContext, at center: CGPoint, radius: CGFloat, intensity: Double) {
        let pinch = radius * 0.08
        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y - radius))
        path.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y), control: CGPoint(x: center.x + pinch, y: center.y - pinch))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius), control: CGPoint(x: center.x + pinch, y: center.y + pinch))
        path.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y), control: CGPoint(x: center.x - pinch, y: center.y + pinch))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius), control: CGPoint(x: center.x - pinch, y: center.y - pinch))
        path.closeSubpath()
        let glow = Gradient(colors: [.white.opacity(intensity), .white.opacity(intensity * 0.35), .clear])
        context.fill(path, with: .radialGradient(glow, center: center, startRadius: 0, endRadius: radius))

        let core = radius * 0.22
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2)),
            with: .radialGradient(
                Gradient(colors: [.white.opacity(intensity), .clear]),
                center: center, startRadius: 0, endRadius: core
            )
        )
    }
}

#Preview {
    IDEWelcomeView()
        .environment(IDEWorkspace())
        .preferredColorScheme(.dark)
}
