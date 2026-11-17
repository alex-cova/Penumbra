import EditorIntelligence
import JavaIntelligence
import SwiftUI

/// A project-level Gradle message (failed task, dependency error, test summary).
struct IDEBuildMessageRowView: View {
    let message: GradleProblem
    var isSelected = false
    let onOpen: () -> Void

    @State private var isHovering = false

    private var severity: DiagnosticSeverity {
        switch message.severity {
        case .error: .error
        case .warning: .warning
        case .info: .information
        }
    }

    private var text: String {
        // Plain until the host wires `onShowTestResults`; the suffix names what a click does.
        message.kind == .testFailures ? "\(message.message) \u{2014} Show Test Results" : message.message
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: IDEAppearance.Spacing.sm) {
                Image(systemName: IDEProblemStyle.symbol(for: severity))
                    .font(.system(size: IDEAppearance.IconSize.rowGlyph))
                    .foregroundStyle(IDEProblemStyle.color(for: severity))
                    .frame(width: 14)
                Text(text)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if let task = message.task {
                    Text(task)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.tight)
            .background(isSelected ? IDEAppearance.ColorToken.selection : (isHovering ? IDEAppearance.ColorToken.controlHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Build \(IDEProblemStyle.label(for: severity)): \(text)")
    }
}
