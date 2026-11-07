import AgentKit
import Penumbra
import SwiftUI

/// Finding an earlier chat by what it was called. Shared by `/resume ` and the history popover.
enum IDEAgentHistorySearch {
    /// Best match first, then newest (the list arrives newest first). An empty query is everything, in order;
    /// with `requiresMatch` a query that matches nothing gives nothing, else it is treated as no filter.
    static func rank(_ summaries: [SessionSummary], query: String, requiresMatch: Bool = false) -> [SessionSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return requiresMatch ? [] : summaries }
        let scored: [(offset: Int, summary: SessionSummary, score: Int)] = summaries.enumerated().compactMap { offset, summary in
            FuzzyMatcher.match(query: trimmed, in: summary.title).map { (offset, summary, $0.score) }
        }
        return scored.sorted { ($0.score, -$0.offset) > ($1.score, -$1.offset) }.map(\.summary)
    }
}

/// The clock button's popover: every saved chat of the project, searchable, newest first.
struct IDEAgentHistoryPopover: View {
    let agent: IDEAgentController
    let dismiss: () -> Void

    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var deleting: SessionSummary?
    @State private var typeahead = IDETypeaheadBuffer()
    @FocusState private var isSearching: Bool
    @FocusState private var isListFocused: Bool

    private var results: [SessionSummary] { IDEAgentHistorySearch.rank(agent.history, query: query) }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search earlier chats", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearching)
                .onSubmit { openSelected() }
                .onKeyPress(.downArrow) {
                    isListFocused = true
                    if selectedID == nil { selectedID = results.first?.id }
                    return .handled
                }
                .onKeyPress(.escape) {
                    if query.isEmpty {
                        dismiss()
                    } else {
                        query = ""
                    }
                    return .handled
                }
                .padding(IDEAppearance.Spacing.sm)
            Divider().overlay(IDEAppearance.ColorToken.border)

            if agent.history.isEmpty {
                message("No earlier chats in this project.")
            } else if results.isEmpty {
                message("No chat matches “\(query)”.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(results) { summary in
                                row(summary)
                                    .id(summary.id)
                            }
                        }
                    }
                    .frame(maxHeight: 340)
                    .focusable()
                    .focused($isListFocused)
                    .focusEffectDisabled()
                    .onKeyPress(phases: [.down, .repeat]) { press in
                        handleListKey(press)
                    }
                    .onChange(of: selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(width: 340)
        .onAppear {
            agent.refreshHistory()
            isSearching = true
        }
        .onChange(of: query) { _, _ in
            if let selectedID, !results.contains(where: { $0.id == selectedID }) {
                self.selectedID = results.first?.id
            }
        }
        .confirmationDialog(
            "Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Chat", role: .destructive) {
                if let deleting { agent.deleteConversation(deleting.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("The conversation and the originals kept for reverting its changes are removed. Files stay as they are.")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .padding(IDEAppearance.Spacing.lg)
            .frame(maxWidth: .infinity)
    }

    private func row(_ summary: SessionSummary) -> some View {
        let isOpen = agent.conversations.contains { $0.conversationID == summary.id }
        let isSelected = selectedID == summary.id
        return Button {
            selectedID = summary.id
            open(summary)
        } label: {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Image(systemName: isOpen ? "bubble.left.fill" : "bubble.left")
                    .font(.system(size: IDEAppearance.IconSize.toolbarGlyph))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.title)
                        .font(IDEAppearance.Typography.body)
                        .foregroundStyle(IDEAppearance.ColorToken.foreground)
                        .lineLimit(1)
                    Text(detail(summary, isOpen: isOpen))
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? IDEAppearance.ColorToken.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { open(summary) }
            Button("Delete…", role: .destructive) { deleting = summary }
                .disabled(agent.conversations.first { $0.conversationID == summary.id }?.isRunning == true)
        }
    }

    private func detail(_ summary: SessionSummary, isOpen: Bool) -> String {
        var parts = [summary.updatedAt.formatted(.relative(presentation: .named))]
        parts.append(summary.messageCount == 1 ? "1 message" : "\(summary.messageCount) messages")
        if let cost = summary.cost { parts.append(IDEAgentPrices.format(cost)) }
        if isOpen { parts.append("open") }
        return parts.joined(separator: "  ·  ")
    }

    private func handleListKey(_ press: KeyPress) -> KeyPress.Result {
        let ids = results.map(\.id)
        switch press.key {
        case .upArrow, .downArrow:
            typeahead.reset()
            if let next = IDEListNeighbor.move(selectedID, in: ids, by: press.key == .downArrow ? 1 : -1) {
                selectedID = next
                isListFocused = true
            }
            return .handled
        case .return:
            typeahead.reset()
            openSelected()
            return .handled
        case .delete, .deleteForward:
            typeahead.reset()
            deleting = results.first { $0.id == selectedID }
            return .handled
        case .escape:
            typeahead.reset()
            dismiss()
            return .handled
        default:
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            if let id = IDEListTypeahead.match(
                query: typeahead.typed(character),
                in: ids,
                selected: selectedID,
                title: { id in results.first { $0.id == id }?.title ?? "" }
            ) {
                selectedID = id
                isListFocused = true
            }
            return .handled
        }
    }

    private func openSelected() {
        if let selectedID, let summary = results.first(where: { $0.id == selectedID }) {
            open(summary)
        } else if let first = results.first {
            open(first)
        }
    }

    private func open(_ summary: SessionSummary) {
        agent.resume(summary.id)
        dismiss()
    }
}
