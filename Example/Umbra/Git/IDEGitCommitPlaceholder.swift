import SwiftUI

/// What the History diff pane shows while no commit is selected: a small commit list, one row
/// highlighted on a branching graph, above a short hint. Drawn with the app's colour tokens so it
/// follows the theme.
struct IDEGitCommitPlaceholder: View {
    var title = "Select a commit"
    var message = "Pick one in the list to see the files it changed and its diff."

    var body: some View {
        VStack(spacing: IDEAppearance.Spacing.md) {
            IDEGitCommitIllustration()
                .frame(width: IDEGitCommitIllustration.size.width, height: IDEGitCommitIllustration.size.height)
                .accessibilityHidden(true)
            VStack(spacing: IDEAppearance.Spacing.xs) {
                Text(title)
                    .font(IDEAppearance.Typography.sectionHeader)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                Text(message)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 260)
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct IDEGitCommitIllustration: View {
    static let size = CGSize(width: 168, height: 96)

    var body: some View {
        Canvas { context, size in
            let rowHeight = size.height / 4
            let mainX: CGFloat = 16
            let branchX: CGFloat = 38
            let textX: CGFloat = 58
            func y(_ row: Int) -> CGFloat { (CGFloat(row) + 0.5) * rowHeight }

            let accent = IDEAppearance.ColorToken.accent
            let branch = IDEAppearance.ColorToken.gitAdded
            let muted = IDEAppearance.ColorToken.muted
            let foreground = IDEAppearance.ColorToken.foreground

            // The "selected" row, as the list draws it.
            let selected = CGRect(x: 0, y: rowHeight + 2, width: size.width, height: rowHeight - 4)
            context.fill(Path(roundedRect: selected, cornerRadius: IDEAppearance.Radius.control), with: .color(IDEAppearance.ColorToken.selection))

            // Text stand-ins: a subject line and a dimmer author line per row.
            let subjectWidths: [CGFloat] = [92, 78, 64, 86]
            for row in 0..<4 {
                let isSelected = row == 1
                let subject = CGRect(x: textX, y: y(row) - 7, width: subjectWidths[row], height: 5)
                let detail = CGRect(x: textX, y: y(row) + 3, width: subjectWidths[row] * 0.55, height: 4)
                context.fill(
                    Path(roundedRect: subject, cornerRadius: 2.5),
                    with: .color((isSelected ? foreground : muted).opacity(isSelected ? 0.55 : 0.4))
                )
                context.fill(
                    Path(roundedRect: detail, cornerRadius: 2),
                    with: .color(muted.opacity(isSelected ? 0.4 : 0.25))
                )
            }

            // Main lane, with a short branch that leaves it and merges back.
            var main = Path()
            main.move(to: CGPoint(x: mainX, y: y(0)))
            main.addLine(to: CGPoint(x: mainX, y: y(3)))
            context.stroke(main, with: .color(accent.opacity(0.8)), lineWidth: 1.5)

            var side = Path()
            side.move(to: CGPoint(x: mainX, y: y(0)))
            side.addCurve(
                to: CGPoint(x: branchX, y: y(1)),
                control1: CGPoint(x: mainX, y: (y(0) + y(1)) / 2),
                control2: CGPoint(x: branchX, y: (y(0) + y(1)) / 2)
            )
            side.addLine(to: CGPoint(x: branchX, y: y(2)))
            side.addCurve(
                to: CGPoint(x: mainX, y: y(3)),
                control1: CGPoint(x: branchX, y: (y(2) + y(3)) / 2),
                control2: CGPoint(x: mainX, y: (y(2) + y(3)) / 2)
            )
            context.stroke(side, with: .color(branch.opacity(0.8)), lineWidth: 1.5)

            // Commits.
            let nodes: [(CGFloat, Int, Color)] = [(mainX, 0, accent), (branchX, 1, branch), (branchX, 2, branch), (mainX, 3, accent)]
            for (x, row, color) in nodes {
                let radius: CGFloat = row == 1 ? 5 : 4
                let dot = CGRect(x: x - radius, y: y(row) - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: dot), with: .color(color))
                if row == 1 {
                    context.stroke(Path(ellipseIn: dot.insetBy(dx: -3, dy: -3)), with: .color(color.opacity(0.45)), lineWidth: 1.5)
                }
            }
        }
    }
}
