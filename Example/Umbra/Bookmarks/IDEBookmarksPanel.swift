import SwiftUI

/// The sidebar's Bookmarks tab: the project's bookmarks, one section per list. A double click
/// opens one; the context menu edits its description and mnemonic and moves it to another list,
/// and a row can be dragged onto another list's header.
struct IDEBookmarksPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if workspace.bookmarks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(workspace.bookmarkLists) { list in
                            IDEBookmarkListSection(list: list, bookmarks: bookmarks(in: list))
                        }
                    }
                    .padding(.vertical, IDEAppearance.Spacing.xs)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IDEAppearance.ColorToken.panel)
    }

    private func bookmarks(in list: IDEBookmarkList) -> [IDEBookmark] {
        workspace.bookmarks
            .filter { $0.listID == list.id }
            .sorted { ($0.filePath, $0.line) < ($1.filePath, $1.line) }
    }

    private var toolbar: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Text(countLabel)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .padding(.leading, IDEAppearance.Spacing.xs)
            Spacer(minLength: 0)
            IDEExplorerToolbarButton(systemImage: "plus", help: "New Bookmark List") {
                workspace.createBookmarkList()
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.xs)
        .frame(height: IDEAppearance.Spacing.iconButton + 4)
    }

    private var countLabel: String {
        let count = workspace.bookmarks.count
        return count == 1 ? "1 bookmark" : "\(count) bookmarks"
    }

    private var emptyState: some View {
        VStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "bookmark")
                .font(.system(size: 14))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text("No bookmarks")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text("Put the caret on a line and use Navigate ▸ Bookmarks ▸ Toggle Bookmark.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .accessibilityElement(children: .combine)
    }
}

/// One list: its header (a drop target) and its bookmarks.
private struct IDEBookmarkListSection: View {
    @Environment(IDEWorkspace.self) private var workspace
    let list: IDEBookmarkList
    let bookmarks: [IDEBookmark]

    @State private var isDropTarget = false

    private var isDefault: Bool { workspace.defaultBookmarkListID == list.id }

    var body: some View {
        header
        ForEach(bookmarks) { bookmark in
            IDEBookmarkRow(bookmark: bookmark)
        }
    }

    private var header: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "list.bullet")
                .font(.system(size: 11))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 14)
            Text(list.name)
                .font(IDEAppearance.Typography.tabLabel.weight(.medium))
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
            if isDefault {
                Text("default")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Text("\(bookmarks.count)")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.top, IDEAppearance.Spacing.sm)
        .padding(.bottom, 2)
        .background(isDropTarget ? IDEAppearance.ColorToken.selection : Color.clear)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { identifiers, _ in
            var moved = false
            for identifier in identifiers {
                guard let id = UUID(uuidString: identifier),
                      let bookmark = workspace.bookmarks.first(where: { $0.id == id }),
                      bookmark.listID != list.id else { continue }
                workspace.moveBookmark(bookmark, toList: list)
                moved = true
            }
            return moved
        } isTargeted: {
            isDropTarget = $0
        }
        .contextMenu {
            Button("Rename…") { workspace.renameBookmarkList(list) }
            Button("Set as Default") { workspace.setDefaultBookmarkList(list) }
                .disabled(isDefault)
            Divider()
            Button("Delete List", role: .destructive) { workspace.deleteBookmarkList(list) }
                .disabled(workspace.bookmarkLists.count < 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct IDEBookmarkRow: View {
    @Environment(IDEWorkspace.self) private var workspace
    let bookmark: IDEBookmark

    @State private var isHovering = false
    @State private var preview: String?

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            badge
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(bookmark.note.isEmpty && preview != nil ? IDEAppearance.Typography.monoSmall : IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(bookmark.fileName):\(bookmark.line)")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if isHovering {
                Button {
                    workspace.removeBookmark(bookmark)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove Bookmark")
                .accessibilityLabel("Remove bookmark")
            }
        }
        .padding(.leading, IDEAppearance.Spacing.sm + IDEAppearance.Spacing.md)
        .padding(.trailing, IDEAppearance.Spacing.sm)
        .padding(.vertical, 3)
        .background(isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { workspace.openBookmark(bookmark) }
        .onHover { isHovering = $0 }
        .draggable(bookmark.id.uuidString)
        .task(id: PreviewKey(id: bookmark.id, line: bookmark.line, path: bookmark.filePath)) {
            preview = await workspace.bookmarkPreview(bookmark)
        }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private struct PreviewKey: Hashable {
        let id: UUID
        let line: Int
        let path: String
    }

    private var headline: String {
        if !bookmark.note.isEmpty { return bookmark.note }
        return preview ?? "\(bookmark.fileName):\(bookmark.line)"
    }

    @ViewBuilder
    private var badge: some View {
        if let mnemonic = bookmark.mnemonic {
            Text(mnemonic)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
                .frame(width: 14, height: 14)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.indigo))
                .accessibilityLabel("Mnemonic \(mnemonic)")
        } else {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.indigo)
                .frame(width: 14, height: 14)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open") { workspace.openBookmark(bookmark) }
        Button("Edit Description…") { workspace.editBookmarkNote(bookmark) }
        Menu("Set Mnemonic") {
            ForEach(IDEBookmarksMnemonicGroup.all) { group in
                Menu(group.title) {
                    ForEach(group.characters, id: \.self) { character in
                        Button(String(character)) { workspace.setBookmarkMnemonic(bookmark, to: String(character)) }
                    }
                }
            }
        }
        if bookmark.mnemonic != nil {
            Button("Remove Mnemonic") { workspace.setBookmarkMnemonic(bookmark, to: nil) }
        }
        let others = workspace.bookmarkLists.filter { $0.id != bookmark.listID }
        if !others.isEmpty {
            Menu("Move to List") {
                ForEach(others) { list in
                    Button(list.name) { workspace.moveBookmark(bookmark, toList: list) }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { workspace.removeBookmark(bookmark) }
    }
}

/// The mnemonic characters in groups short enough for a menu.
private struct IDEBookmarksMnemonicGroup: Identifiable {
    let title: String
    let characters: [Character]
    var id: String { title }

    static let all: [IDEBookmarksMnemonicGroup] = [
        IDEBookmarksMnemonicGroup(title: "0–9", characters: Array("1234567890")),
        IDEBookmarksMnemonicGroup(title: "A–M", characters: Array("ABCDEFGHIJKLM")),
        IDEBookmarksMnemonicGroup(title: "N–Z", characters: Array("NOPQRSTUVWXYZ"))
    ]
}

extension IDEWorkspace {
    /// The text of the bookmarked line, trimmed: from the open buffer when the file is open, else
    /// read from disk off the main actor (files over 5 MB are skipped, and so is a missing one).
    func bookmarkPreview(_ bookmark: IDEBookmark) async -> String? {
        let url = bookmark.url
        if let text = openBufferText(for: url) {
            return Self.line(bookmark.line, in: text)
        }
        let line = bookmark.line
        return await Task.detached(priority: .utility) { () -> String? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int, size <= 5_000_000,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return Self.line(line, in: text)
        }.value
    }

    /// The 1-based `line` of `text`, trimmed and capped; nil when it is blank or past the end.
    nonisolated static func line(_ line: Int, in text: String) -> String? {
        var current = 1
        var start = text.startIndex
        while current < line {
            guard let newline = text[start...].firstIndex(of: "\n") else { return nil }
            start = text.index(after: newline)
            current += 1
        }
        let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
        let trimmed = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(160))
    }
}
