import SwiftUI

/// The tray button beside + while drafts are stashed: its badge counts them and its popover lists them,
/// newest first. A click brings one back (what the field held is stashed in its place); × drops one.
struct IDEAgentStashButton: View {
    let agent: IDEAgentController
    let stash: IDEAgentPromptStash
    @State private var isPresented = false

    var body: some View {
        IDEIconButton(
            systemImage: "tray.full", help: "Stashed drafts (⌃S stashes the one you are writing)",
            tint: IDEAppearance.ColorToken.muted, isActive: isPresented, badge: stash.entries.count
        ) { isPresented.toggle() }
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                list.frame(width: 340)
            }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Stashed Drafts")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .padding(IDEAppearance.Spacing.sm)
            Divider().overlay(IDEAppearance.ColorToken.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(stash.entries) { entry in
                        row(entry)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private func row(_ entry: IDEAgentPromptStash.Entry) -> some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Button {
                isPresented = false
                agent.restoreStashed(entry.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(IDEAppearance.Typography.body)
                        .foregroundStyle(IDEAppearance.ColorToken.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: IDEAppearance.Spacing.xs) {
                        Text(entry.createdAt, style: .relative)
                        if !entry.images.isEmpty {
                            Label("\(entry.images.count)", systemImage: "photo")
                        }
                    }
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Put this draft back in the message field")
            .accessibilityLabel("Restore draft: \(entry.title)")
            IDEIconButton(systemImage: "xmark", help: "Drop this draft") { stash.remove(entry.id) }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }
}
