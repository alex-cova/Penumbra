import SwiftUI

/// The window's top-right cards: live Gradle sync and background-indexing progress (read straight
/// from `IDEJavaSupport`, gone when the work finishes) above the latest notification, which the
/// notification center announces and later keeps in the bell's list.
struct IDEStatusToast: View {
    @Environment(IDEWorkspace.self) private var workspace
    private var java: IDEJavaSupport { workspace.javaSupport }

    private enum Content: Equatable {
        case syncing(message: String)
        case working(message: String)
    }

    private var content: Content? {
        guard let message = java.statusMessage else { return nil }
        return java.gradleSync.isSyncing ? .syncing(message: message) : .working(message: message)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: IDEAppearance.Spacing.sm) {
            if let content {
                card(content)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let notification = workspace.notifications.toast {
                notificationCard(notification)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: content)
        .animation(.easeOut(duration: 0.18), value: workspace.notifications.toast)
    }

    @ViewBuilder
    private func card(_ content: Content) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            switch content {
            case .syncing(let message):
                Button(action: workspace.showGradleOutput) {
                    HStack(spacing: IDEAppearance.Spacing.sm) {
                        spinner
                        TimelineView(.periodic(from: java.gradleConsole.startedAt ?? .now, by: 1)) { context in
                            Text(syncingSummary(message, now: context.date))
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Show Gradle output")
                .accessibilityLabel("Gradle sync in progress")
                .accessibilityHint(message)
            case .working(let message):
                spinner
                Text(message)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(IDEAppearance.Typography.monoSmall)
        .toastChrome()
    }

    private func notificationCard(_ notification: IDENotification) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Button {
                workspace.activate(notification)
            } label: {
                HStack(spacing: IDEAppearance.Spacing.sm) {
                    Image(systemName: notification.severity.symbolName)
                        .foregroundStyle(notification.severity.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notification.title)
                            .foregroundStyle(notification.severity == .error ? notification.severity.tint : IDEAppearance.ColorToken.foreground)
                        if let detail = notification.detail {
                            Text(detail)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
            }
            .buttonStyle(.plain)
            .disabled(notification.action == nil)
            .help(notification.detail ?? notification.title)
            Button {
                workspace.notifications.dismissToast()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: IDEAppearance.IconSize.breadcrumbChevron, weight: .semibold))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .font(IDEAppearance.Typography.monoSmall)
        .toastChrome()
    }

    private var spinner: some View {
        ProgressView()
            .controlSize(.small)
            .scaleEffect(0.65)
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }

    /// "Resolving Gradle project… · 0:42 · > Task :app:umbraProjectModelFragment" -- the status
    /// message plus elapsed time plus the latest console line, all in the one truncating label.
    private func syncingSummary(_ message: String, now: Date) -> String {
        var parts = [message]
        if let startedAt = java.gradleConsole.startedAt {
            let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
            parts.append(String(format: "%d:%02d", elapsed / 60, elapsed % 60))
        }
        if let latest = java.gradleConsole.latestLine {
            parts.append(latest)
        }
        return parts.joined(separator: "  ·  ")
    }
}

private extension View {
    /// The card every toast shares.
    func toastChrome() -> some View {
        padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.sm)
            .frame(maxWidth: 420)
            .background(
                IDEAppearance.ColorToken.card,
                in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.panel, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: IDEAppearance.Radius.panel, style: .continuous)
                    .strokeBorder(IDEAppearance.ColorToken.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .accessibilityElement(children: .contain)
    }
}
