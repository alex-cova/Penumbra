import SwiftUI

struct IDEStatusBarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Text(leadingSummary)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            if !workspace.showsWelcome {
                Text("·")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                syntaxPicker
            }
            javaStatus
            httpStatus
            if workspace.statusSelectionLength > 0 {
                Text("·  \(workspace.statusSelectionLength) selected")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Spacer()
            Text(trailingSummary)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .frame(height: IDEAppearance.Spacing.statusBarHeight)
        .background(IDEAppearance.ColorToken.statusBar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
        }
        .focusable(false)
    }

    /// Sublime-style clickable syntax name for untitled or extensionless files. Known file types
    /// (e.g. `.java`) show a read-only label instead.
    @ViewBuilder
    private var syntaxPicker: some View {
        let label = Text(
            IDELanguageSupport.displayName(
                forIdentifier: workspace.statusLanguage.isEmpty ? nil : workspace.statusLanguage
            )
        )
        .font(IDEAppearance.Typography.monoSmall)
        .foregroundStyle(IDEAppearance.ColorToken.muted)

        if workspace.canChangeActiveLanguage {
            Menu {
                ForEach(IDELanguageSupport.selectableSyntaxes) { option in
                    Button(option.displayName) {
                        workspace.setLanguage(identifier: option.id)
                    }
                }
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else {
            label
                .fixedSize()
        }
    }

    @ViewBuilder
    private var javaStatus: some View {
        switch workspace.javaSupport.gradleSync {
        case .failed(let summary):
            Text("·")
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Button("Gradle sync failed") {
                workspace.showGradleOutput()
            }
            .buttonStyle(.borderless)
            .font(IDEAppearance.Typography.monoSmall)
            .foregroundStyle(IDEAppearance.ColorToken.error)
            .fixedSize()
            .help(summary)
            .accessibilityLabel("Gradle sync failed")
            .accessibilityHint(summary)
        case .syncing:
            if let message = workspace.javaSupport.statusMessage {
                Text("·")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Button {
                    workspace.showGradleOutput()
                } label: {
                    HStack(spacing: IDEAppearance.Spacing.sm) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.65)
                            .frame(width: 12, height: 12)
                            .accessibilityHidden(true)
                        TimelineView(.periodic(from: workspace.javaSupport.gradleConsole.startedAt ?? .now, by: 1)) { context in
                            Text(syncingSummary(message, now: context.date))
                                .font(IDEAppearance.Typography.monoSmall)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 280, alignment: .leading)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .help("Show Gradle output")
                .accessibilityLabel("Gradle sync in progress")
                .accessibilityHint(message)
            }
        default:
            if let message = workspace.javaSupport.statusMessage {
                Text("·")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(message)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 280, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var httpStatus: some View {
        if workspace.statusLanguage == "http" {
            if workspace.httpSupport.isSending {
                Text("·")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Button("Sending HTTP request…") {
                    workspace.showHTTPResponse()
                }
                .buttonStyle(.borderless)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else if let statusCode = workspace.httpSupport.lastStatusCode,
                      let duration = workspace.httpSupport.lastDuration {
                Text("·")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Button("HTTP \(statusCode) (\(Int(duration * 1000)) ms)") {
                    workspace.showHTTPResponse()
                }
                .buttonStyle(.borderless)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
    }

    /// "Resolving Gradle project · 0:42 · > Task :app:umbraProjectModelFragment" -- the status
    /// message plus elapsed time plus the latest console line, all in the one truncating label.
    private func syncingSummary(_ message: String, now: Date) -> String {
        var parts = [message]
        if let startedAt = workspace.javaSupport.gradleConsole.startedAt {
            let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
            parts.append(String(format: "%d:%02d", elapsed / 60, elapsed % 60))
        }
        if let latest = workspace.javaSupport.gradleConsole.latestLine {
            parts.append(latest)
        }
        return parts.joined(separator: "  ·  ")
    }

    private var leadingSummary: String {
        "Ln \(workspace.statusLine)  ·  Col \(workspace.statusColumn)"
    }

    private var trailingSummary: String {
        var parts = ["UTF-8", "LF"]
        if workspace.isTerminalVisible {
            parts.append("Terminal")
        }
        parts.append(workspace.statusRenderer)
        parts.append("Umbra")
        return parts.joined(separator: "  ·  ")
    }
}

#Preview {
    IDEStatusBarPanel()
        .environment({
            let workspace = IDEWorkspace()
            workspace.statusLine = 12
            workspace.statusColumn = 4
            workspace.statusLanguage = "javascript"
            return workspace
        }())
        .preferredColorScheme(.dark)
}
