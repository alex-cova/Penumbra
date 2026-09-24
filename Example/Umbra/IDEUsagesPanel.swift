import EditorIntelligence
import Observation
import SwiftUI

/// One file's worth of usages in the Usages tab.
struct IDEUsageFile: Identifiable {
    let url: URL
    let usages: [Location]

    var id: URL { url }
}

/// What the Usages tab shows: the result of the last Find Usages, grouped by file.
@MainActor
@Observable
final class IDEUsagesStore {
    private(set) var files: [IDEUsageFile] = []
    private(set) var count = 0
    /// True from the moment a search starts until it finishes or is cancelled.
    private(set) var isSearching = false
    private(set) var hasContent = false
    @ObservationIgnored private var cancelSearch: (() -> Void)?

    func beginSearch(cancel: @escaping () -> Void) {
        cancelSearch = cancel
        isSearching = true
        hasContent = true
    }

    func finishSearch() {
        isSearching = false
        cancelSearch = nil
    }

    func cancel() {
        cancelSearch?()
        finishSearch()
    }

    func show(_ locations: [Location]) {
        var order: [URL] = []
        var grouped: [URL: [Location]] = [:]
        for location in locations {
            guard let url = location.url else { continue }
            if grouped[url] == nil { order.append(url) }
            grouped[url, default: []].append(location)
        }
        files = order.map { IDEUsageFile(url: $0, usages: grouped[$0] ?? []) }
        count = locations.count
        hasContent = true
    }

    func clear() {
        cancel()
        files = []
        count = 0
        hasContent = false
    }
}

/// The bottom panel's Usages tab: Find Usages results grouped by file, each row a source line with
/// the match emphasised, a kind badge, and a marker when the resolver could not pin the overload.
struct IDEUsagesPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var collapsedFiles: Set<URL> = []

    var body: some View {
        let store = workspace.usages
        Group {
            if store.files.isEmpty {
                VStack(spacing: IDEAppearance.Spacing.xs) {
                    if store.isSearching {
                        ProgressView().controlSize(.small)
                    }
                    Text(store.isSearching ? "Searching for usages…" : "No usages")
                        .font(IDEAppearance.Typography.body)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.files) { file in
                            fileHeader(file)
                            if !collapsedFiles.contains(file.url) {
                                ForEach(file.usages) { location in
                                    IDEUsageRowView(location: location) { _ = workspace.openNavigationLocation(location) }
                                }
                            }
                        }
                    }
                    .padding(.vertical, IDEAppearance.Spacing.xs)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func fileHeader(_ file: IDEUsageFile) -> some View {
        let isCollapsed = collapsedFiles.contains(file.url)
        return Button {
            if isCollapsed { collapsedFiles.remove(file.url) } else { collapsedFiles.insert(file.url) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                Text(file.url.lastPathComponent)
                    .font(IDEAppearance.Typography.sidebarHeader)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                Text(workspace.displayDirectory(of: file.url))
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                Text("\(file.usages.count)")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(file.url.lastPathComponent), \(file.usages.count) usages")
        .accessibilityHint(isCollapsed ? "Expand" : "Collapse")
    }
}

private struct IDEUsageRowView: View {
    let location: Location
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\((location.usage?.line ?? location.range.start.line) + 1)")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(minWidth: 36, alignment: .trailing)
                preview
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if location.usage?.isAmbiguous == true {
                    Text("?")
                        .font(IDEAppearance.Typography.monoSmall.weight(.bold))
                        .foregroundStyle(IDEAppearance.ColorToken.gitModified)
                        .help("Could not tell which overload or receiver this is; it may belong to a sibling")
                }
                if let kind = location.usage?.kindLabel {
                    Text(kind)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(IDEAppearance.ColorToken.controlHover)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }
            .padding(.leading, IDEAppearance.Spacing.xl)
            .padding(.trailing, IDEAppearance.Spacing.md)
            .padding(.vertical, 3)
            .background(isHovering ? IDEAppearance.ColorToken.controlHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Line \((location.usage?.line ?? 0) + 1): \(location.usage?.lineText ?? location.displayName)")
    }

    /// The source line with leading whitespace trimmed and the matched identifier in bold.
    private var preview: Text {
        guard let usage = location.usage else { return Text(location.displayName).font(IDEAppearance.Typography.body) }
        let line = usage.lineText as NSString
        var lead = 0
        while lead < line.length, [32, 9].contains(line.character(at: lead)) { lead += 1 }
        let match = usage.matchRange
        guard match.location >= lead, NSMaxRange(match) <= line.length else {
            return Text(line.substring(from: lead)).font(IDEAppearance.Typography.body)
        }
        let before = line.substring(with: NSRange(location: lead, length: match.location - lead))
        let hit = line.substring(with: match)
        let after = line.substring(from: NSMaxRange(match))
        return Text(before).foregroundStyle(IDEAppearance.ColorToken.muted)
            + Text(hit).bold().foregroundStyle(IDEAppearance.ColorToken.accent)
            + Text(after).foregroundStyle(IDEAppearance.ColorToken.muted)
    }
}

/// Header controls shown while the Usages tab is selected: the count, and Cancel during a search.
struct IDEUsagesControls: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let store = workspace.usages
        HStack(spacing: IDEAppearance.Spacing.sm) {
            if store.isSearching {
                ProgressView().controlSize(.small)
                Button("Cancel") { store.cancel() }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Cancel search")
            } else {
                Text("\(store.count) usages")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Button {
                workspace.closeUsages()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .help("Close Usages")
            .accessibilityLabel("Close Usages")
        }
    }
}

/// Tab-strip item for the Usages tab.
struct IDEUsagesTabItem: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 12)
            Text(title)
                .foregroundStyle(isSelected ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .font(IDEAppearance.Typography.tabLabel.weight(isSelected ? .medium : .regular))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .overlay(alignment: .top) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(IDEAppearance.ColorToken.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .focusable(false)
    }

    private var backgroundColor: Color {
        if isSelected { return IDEAppearance.ColorToken.tabActive }
        if isHovering { return IDEAppearance.ColorToken.tabHover }
        return IDEAppearance.ColorToken.tabInactive
    }
}
