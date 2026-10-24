import AppKit
import SwiftUI

/// The buttons at the right of a project system's console tab: how long the run took, Cancel while
/// it works (Reload when idle) and Copy Output. One view for every `IDEProjectSystem`.
struct IDEProjectConsoleControls: View {
    let system: any IDEProjectSystem

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            elapsedTime
            if system.isBusy {
                Button("Cancel", action: cancel)
                    .buttonStyle(.borderless)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else {
                button("arrow.clockwise", help: "Reload \(system.displayName) Project", action: system.reload)
            }
            button("doc.on.doc", help: "Copy \(system.displayName) Output", action: copyOutput)
        }
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .help(help)
            .accessibilityLabel(help)
    }

    @ViewBuilder
    private var elapsedTime: some View {
        let console = system.console
        if let startedAt = console.startedAt {
            if system.isBusy {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    elapsedLabel(context.date.timeIntervalSince(startedAt))
                }
            } else if let finishedAt = console.finishedAt {
                elapsedLabel(finishedAt.timeIntervalSince(startedAt))
            }
        }
    }

    private func elapsedLabel(_ interval: TimeInterval) -> some View {
        Text(Self.formattedElapsed(interval))
            .font(IDEAppearance.Typography.monoSmall)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
    }

    /// A sync in progress is what the user cancels first; otherwise it is the running tasks.
    private func cancel() {
        if system.syncState.isSyncing {
            system.cancelSync()
        } else {
            system.cancelTasks()
        }
    }

    private func copyOutput() {
        let text = system.console.lines.map(\.text).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func formattedElapsed(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
