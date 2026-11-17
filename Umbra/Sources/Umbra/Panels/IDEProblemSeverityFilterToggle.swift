import EditorIntelligence
import SwiftUI

/// An Errors/Warnings filter toggle of the Problems panel header.
struct IDEProblemSeverityFilterToggle: View {
    @Environment(IDEWorkspace.self) private var workspace
    let severity: DiagnosticSeverity
    let count: Int
    let label: String

    var body: some View {
        let isOn = workspace.problems.visibleSeverities.contains(severity)
        return Button(action: toggle) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Image(systemName: IDEProblemStyle.symbol(for: severity))
                    .font(.system(size: IDEAppearance.IconSize.smallGlyph))
                Text("\(count)")
                    .font(IDEAppearance.Typography.monoSmall)
            }
            .foregroundStyle(isOn ? IDEProblemStyle.color(for: severity) : IDEAppearance.ColorToken.muted.opacity(IDEAppearance.Opacity.dimmed))
        }
        .buttonStyle(.borderless)
        .help("\(isOn ? "Hide" : "Show") \(label)")
        .accessibilityLabel("\(label): \(count)")
        .accessibilityValue(isOn ? "shown" : "hidden")
    }

    private func toggle() {
        workspace.problems.toggleSeverity(severity)
        if severity == .warning {
            // Informational and hint rows ride along with the warning filter.
            workspace.problems.toggleSeverity(.information)
            workspace.problems.toggleSeverity(.hint)
        }
    }
}
