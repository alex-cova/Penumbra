import Foundation

/// Coordinates split editor layout and per-pane tab groups.
public final class EditorWorkbench: Identifiable, @unchecked Sendable {
    public let id: UUID
    public var layout: EditorLayout
    public var activePaneID: UUID
    /// Cross-document back/forward cursor history (⌘[ / ⌘]). Assign this instance to every
    /// pane's `TextView.navigationHistory` (see `PenumbraWorkbenchEditorAdapter`) so ⌘[ can
    /// step back into a previously visited document.
    public let navigationHistory = NavigationHistory()

    public var panes: [EditorPane] {
        layout.flattenedPanes()
    }

    public var activePane: EditorPane {
        layout.findPane(id: activePaneID) ?? panes[0]
    }

    public init(id: UUID = UUID()) {
        let pane = EditorPane()
        self.id = id
        self.layout = .horizontal(EditorSplitData(axis: .horizontal, children: [.pane(pane)]))
        self.activePaneID = pane.id
    }

    public func activatePane(_ paneID: UUID) {
        guard layout.findPane(id: paneID) != nil else { return }
        activePaneID = paneID
    }

    public func openDocument(
        _ document: WorkbenchDocument,
        in pane: EditorPane? = nil,
        asTemporary: Bool = false
    ) {
        let target = pane ?? activePane
        target.openDocument(document, asTemporary: asTemporary)
    }

    public func allDocuments() -> [WorkbenchDocument] {
        var seen = Set<UUID>()
        var documents: [WorkbenchDocument] = []
        for pane in panes {
            for document in pane.documents where !seen.contains(document.id) {
                seen.insert(document.id)
                documents.append(document)
            }
        }
        return documents
    }

    /// Open documents in most-recently-used order, for a ⌘E "recent files" palette. Ordering
    /// comes from the active pane's tab history (`EditorTabHistory`); documents never selected
    /// yet trail in tab order.
    public func recentDocuments(limit: Int = 20) -> [WorkbenchDocument] {
        let byID = Dictionary(uniqueKeysWithValues: allDocuments().map { ($0.id, $0) })
        var ordered: [WorkbenchDocument] = []
        var seen = Set<UUID>()
        for id in activePane.tabHistory.snapshotEntries() where !seen.contains(id) {
            if let document = byID[id] {
                seen.insert(id)
                ordered.append(document)
            }
        }
        for document in allDocuments() where !seen.contains(document.id) {
            seen.insert(document.id)
            ordered.append(document)
        }
        return Array(ordered.prefix(limit))
    }

    @discardableResult
    public func splitActivePane(
        edge: EditorSplitEdge,
        newPane: EditorPane? = nil
    ) -> EditorPane {
        let pane = newPane ?? EditorPane()
        layout.splitPane(activePaneID, edge: edge, newPane: pane)
        activePaneID = pane.id
        return pane
    }

    public func closePane(_ paneID: UUID) {
        if activePaneID == paneID {
            if let replacement = layout.findSomePane(except: paneID) {
                activePaneID = replacement.id
            }
        }
        layout.closePane(paneID)
        layout.flatten()
        if panes.isEmpty {
            initCleanLayout()
        } else if layout.findPane(id: activePaneID) == nil {
            activePaneID = panes[0].id
        }
    }

    public func makeRestorationState() -> EditorRestorationState {
        EditorRestorationState(activePaneID: activePaneID, layout: EditorLayoutSnapshot(layout: layout))
    }

    /// Synchronous layout restore. File-backed documents have empty `text` until
    /// ``reloadFileBackedDocuments()``.
    public func restore(
        from state: EditorRestorationState,
        languageResolver: (WorkbenchDocumentSnapshot) -> TreeSitterLanguage? = { _ in nil }
    ) {
        layout = state.layout.makeLayout(languageResolver: languageResolver)
        layout.flatten()
        if layout.flattenedPanes().isEmpty {
            initCleanLayout()
            return
        }
        if let restoredActive = layout.findPane(id: state.activePaneID) {
            activePaneID = restoredActive.id
        } else if let fallback = layout.findSomePane() {
            activePaneID = fallback.id
        } else {
            initCleanLayout()
        }
    }

    /// For each document with `isFileBacked && url != nil`, ``WorkbenchDocument/load(contentsOf:language:languageIdentifier:parsePolicy:io:)``
    /// and splice `id`, `documentID`, selection, scroll, and `isDirty` onto the loaded instance
    /// (loaded `pendingState` / `rangeReader` / `isFileBacked` win). Dirty mmap edits are discarded.
    public func reloadFileBackedDocuments(
        languageResolver: (WorkbenchDocument) -> TreeSitterLanguage? = { _ in nil }
    ) async throws {
        var replacements: [UUID: WorkbenchDocument] = [:]
        for document in allDocuments() {
            guard document.isFileBacked, let url = document.url else {
                continue
            }
            let loaded = try await WorkbenchDocument.load(
                contentsOf: url,
                language: languageResolver(document) ?? document.language,
                languageIdentifier: document.languageIdentifier
            )
            let spliced = WorkbenchDocument(
                id: document.id,
                documentID: document.documentID,
                url: loaded.url,
                displayName: loaded.displayName,
                text: loaded.text,
                language: loaded.language ?? document.language,
                languageIdentifier: loaded.languageIdentifier ?? document.languageIdentifier,
                isDirty: document.isDirty,
                selectedRange: document.selectedRange,
                scrollOffset: document.scrollOffset
            )
            spliced.pendingState = loaded.pendingState
            spliced.isFileBacked = loaded.isFileBacked
            spliced.rangeReader = loaded.rangeReader
            replacements[document.id] = spliced
        }
        guard !replacements.isEmpty else {
            return
        }
        for pane in panes {
            pane.documents = pane.documents.map { replacements[$0.id] ?? $0 }
        }
    }

    /// ``restore(from:languageResolver:)`` then, if `reloadingFileBacked`, ``reloadFileBackedDocuments()``.
    public func restore(
        from state: EditorRestorationState,
        reloadingFileBacked: Bool,
        languageResolver: (WorkbenchDocumentSnapshot) -> TreeSitterLanguage? = { _ in nil }
    ) async throws {
        restore(from: state, languageResolver: languageResolver)
        if reloadingFileBacked {
            try await reloadFileBackedDocuments { $0.language }
        }
    }

    public func initCleanLayout() {
        let pane = EditorPane()
        layout = .horizontal(EditorSplitData(axis: .horizontal, children: [.pane(pane)]))
        activePaneID = pane.id
    }
}
