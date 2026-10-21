import AppKit
import Penumbra

/// Bookmarks (IntelliJ's): a line of a file you want to get back to. Anonymous ones are toggled
/// at the caret; a mnemonic (a digit or a letter) names one so it can be reached by key. The
/// store (`IDEBookmarkStore`) is shared by every window; this is the window's side: the gutter
/// icons, the actions and the Bookmarks tab's state.
extension IDEWorkspace {
    // MARK: - State and gutter

    /// Re-reads the project's bookmarks and redraws them in every open editor.
    func refreshBookmarks() {
        reloadBookmarkMirror()
        for pane in workbench.panes {
            guard let host = hostCache.peek(pane.id) else { continue }
            applyBookmarkGutter(to: host, document: pane.selectedDocument)
        }
    }

    /// Only the arrays the Bookmarks tab reads; the gutters are already right (an edit moved them).
    func reloadBookmarkMirror() {
        let snapshot = bookmarkStore.snapshot(project: project.rootURL)
        bookmarks = snapshot.bookmarks
        bookmarkLists = snapshot.lists
        defaultBookmarkListID = snapshot.defaultListID
    }

    /// Draws `document`'s bookmarks in the gutter of `host` and listens for clicks and for edits
    /// that move them. A document with no file, or that is not text, shows none.
    func applyBookmarkGutter(to host: IDEEditorPaneHost, document: WorkbenchDocument?) {
        let textView = host.textView
        guard let document, document.contentKind == .text, let url = document.url?.standardizedFileURL else {
            textView.setGutterBookmarks([])
            textView.gutterBookmarkHandler = nil
            textView.gutterBookmarksDidMove = nil
            return
        }
        let shown = bookmarkStore.bookmarks(forFile: url, project: project.rootURL)
        textView.setGutterBookmarks(shown.map { bookmark in
            GutterBookmark(
                id: bookmark.id.uuidString, line: bookmark.line,
                mnemonic: bookmark.mnemonic?.first, note: bookmark.note.isEmpty ? nil : bookmark.note
            )
        })
        let shownIDs = Set(shown.map(\.id))
        textView.gutterBookmarkHandler = { [weak self] clicked in
            guard let self, let id = UUID(uuidString: clicked.id),
                  let bookmark = self.bookmarks.first(where: { $0.id == id }) else { return }
            if NSEvent.modifierFlags.contains(.option) {
                self.editBookmarkNote(bookmark)
            } else {
                self.removeBookmark(bookmark)
            }
        }
        textView.gutterBookmarksDidMove = { [weak self] moved in
            guard let self else { return }
            var lines: [UUID: Int] = [:]
            for bookmark in moved {
                if let id = UUID(uuidString: bookmark.id) { lines[id] = bookmark.line }
            }
            if self.bookmarkStore.moveLines(in: url, to: lines, removing: shownIDs.subtracting(lines.keys), project: self.project.rootURL) {
                self.reloadBookmarkMirror()
            }
        }
    }

    // MARK: - At the caret

    /// The file, text view and 1-based caret line of the active editor.
    private func activeBookmarkTarget() -> (url: URL, textView: TextView, line: Int)? {
        guard let document = workbench.activePane.selectedDocument, document.contentKind == .text,
              let url = document.url?.standardizedFileURL else { return nil }
        let textView = host(for: workbench.activePaneID).textView
        let line = (textView.textLocation(at: textView.selectedRange.location)?.lineNumber ?? 0) + 1
        return (url, textView, line)
    }

    /// Toggle Bookmark: adds an anonymous bookmark on the caret's line, or removes the one there.
    func toggleBookmarkAtCaret() {
        guard let target = activeBookmarkTarget() else { return NSSound.beep() }
        bookmarkStore.toggle(atLine: target.line, file: target.url, project: project.rootURL)
        refreshBookmarks()
    }

    /// Toggle Bookmark with Mnemonic: a list of the digits and letters; the chosen one names the
    /// bookmark on the caret's line (added when the line has none). "No Mnemonic" keeps the
    /// bookmark and takes its name away. A mnemonic in use moves here from its old line.
    func assignBookmarkMnemonicAtCaret() {
        guard let target = activeBookmarkTarget(), let paletteController else { return NSSound.beep() }
        let root = project.rootURL
        let current = bookmarkStore.bookmark(atLine: target.line, file: target.url, project: root)
        var entries: [(title: String, subtitle: String?, mnemonic: String?)] = []
        if current?.mnemonic != nil {
            entries.append(("No Mnemonic", "Keep the bookmark, drop its name", nil))
        }
        for character in IDEBookmarkMnemonic.characters {
            let name = String(character)
            let owner = bookmarkStore.bookmark(withMnemonic: name, project: root)
            let subtitle: String
            if owner?.id == current?.id {
                subtitle = "This bookmark"
            } else if let owner {
                subtitle = "Moves here from \(owner.fileName):\(owner.line)"
            } else {
                subtitle = "Free"
            }
            entries.append((name, subtitle, name))
        }
        paletteController.presentList(
            title: "Bookmark Mnemonic", items: entries.map { (title: $0.title, subtitle: $0.subtitle) }
        ) { [weak self] index in
            guard let self, entries.indices.contains(index) else { return }
            self.bookmarkStore.setMnemonic(entries[index].mnemonic, atLine: target.line, file: target.url, project: root)
            self.refreshBookmarks()
        }
    }

    /// Show Bookmarks: every bookmark of the project; the chosen one opens.
    func showBookmarksList() {
        guard let paletteController else { return }
        let ordered = bookmarkStore.ordered(project: project.rootURL)
        guard !ordered.isEmpty else { return NSSound.beep() }
        let items = ordered.map { bookmark -> (title: String, subtitle: String?) in
            let prefix = bookmark.mnemonic.map { "[\($0)] " } ?? ""
            let location = "\(bookmark.fileName):\(bookmark.line)"
            return (prefix + (bookmark.note.isEmpty ? location : bookmark.note), bookmark.note.isEmpty ? relativePath(of: bookmark) : location)
        }
        paletteController.presentList(title: "Bookmarks", items: items) { [weak self] index in
            guard let self, ordered.indices.contains(index) else { return }
            self.openBookmark(ordered[index])
        }
    }

    private func relativePath(of bookmark: IDEBookmark) -> String {
        guard let root = project.rootURL?.standardizedFileURL.path, bookmark.filePath.hasPrefix(root + "/") else {
            return bookmark.filePath
        }
        return String(bookmark.filePath.dropFirst(root.count + 1))
    }

    /// Next / Previous Bookmark: by file path then line, wrapping around.
    func goToBookmark(forward: Bool) {
        let position: (filePath: String, line: Int)
        if let target = activeBookmarkTarget() {
            position = (target.url.path, target.line)
        } else {
            position = ("", 0)
        }
        guard let bookmark = bookmarkStore.neighbour(of: position, forward: forward, project: project.rootURL) else {
            return NSSound.beep()
        }
        openBookmark(bookmark)
    }

    /// Go to Bookmark 1 … 9, 0, A … Z.
    func goToBookmark(mnemonic: String) {
        guard let bookmark = bookmarkStore.bookmark(withMnemonic: mnemonic, project: project.rootURL) else {
            return NSSound.beep()
        }
        openBookmark(bookmark)
    }

    func openBookmark(_ bookmark: IDEBookmark) {
        revealDebugStop(file: bookmark.url, line: bookmark.line, selectsLine: false)
    }

    // MARK: - From the Bookmarks tab

    func removeBookmark(_ bookmark: IDEBookmark) {
        bookmarkStore.remove(bookmarkID: bookmark.id, project: project.rootURL)
        refreshBookmarks()
    }

    func moveBookmark(_ bookmark: IDEBookmark, toList list: IDEBookmarkList) {
        bookmarkStore.move(bookmarkID: bookmark.id, toList: list.id, project: project.rootURL)
        refreshBookmarks()
    }

    func setBookmarkMnemonic(_ bookmark: IDEBookmark, to mnemonic: String?) {
        bookmarkStore.setMnemonic(mnemonic, atLine: bookmark.line, file: bookmark.url, project: project.rootURL)
        refreshBookmarks()
    }

    func editBookmarkNote(_ bookmark: IDEBookmark) {
        promptForText(title: "Bookmark Description", message: bookmark.title, initial: bookmark.note, confirm: "Save") { [weak self] note in
            guard let self else { return }
            self.bookmarkStore.setNote(note, bookmarkID: bookmark.id, project: self.project.rootURL)
            self.refreshBookmarks()
        }
    }

    func createBookmarkList() {
        promptForText(title: "New Bookmark List", message: "Name the list.", initial: "", confirm: "Create") { [weak self] name in
            guard let self, !name.isEmpty else { return }
            self.bookmarkStore.createList(named: name, project: self.project.rootURL)
            self.refreshBookmarks()
        }
    }

    func renameBookmarkList(_ list: IDEBookmarkList) {
        promptForText(title: "Rename Bookmark List", message: list.name, initial: list.name, confirm: "Rename") { [weak self] name in
            guard let self, !name.isEmpty else { return }
            self.bookmarkStore.renameList(list.id, to: name, project: self.project.rootURL)
            self.refreshBookmarks()
        }
    }

    func setDefaultBookmarkList(_ list: IDEBookmarkList) {
        bookmarkStore.setDefaultList(list.id, project: project.rootURL)
        refreshBookmarks()
    }

    func deleteBookmarkList(_ list: IDEBookmarkList) {
        bookmarkStore.deleteList(list.id, project: project.rootURL)
        refreshBookmarks()
    }

    // MARK: - Commands

    /// Runs an editor action on the active pane's text view (the Navigate menu's way to the
    /// actions the keymap also binds).
    func performEditorAction(_ action: EditorActionID) {
        _ = host(for: workbench.activePaneID).textView.perform(action)
    }

    /// The mnemonics in use, in the order the Bookmarks menu lists them.
    var bookmarksWithMnemonics: [IDEBookmark] {
        bookmarks.filter { $0.mnemonic != nil }.sorted { ($0.mnemonic ?? "") < ($1.mnemonic ?? "") }
    }

    // MARK: - Prompt

    /// One line of text in a sheet on this window; `onConfirm` gets the trimmed text.
    private func promptForText(title: String, message: String, initial: String, confirm: String, onConfirm: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            onConfirm(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
