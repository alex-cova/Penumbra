import Foundation

/// One editor pane's tab group (tabs, selection, preview tab, navigation history).
public final class EditorPane: Identifiable, @unchecked Sendable {
    public let id: UUID
    public var documents: [WorkbenchDocument]
    public var selectedDocumentID: UUID?
    public var temporaryDocumentID: UUID?
    public let tabHistory = EditorTabHistory()

    public init(id: UUID = UUID()) {
        self.id = id
        self.documents = []
    }

    public var selectedDocument: WorkbenchDocument? {
        guard let selectedDocumentID else { return nil }
        return documents.first { $0.id == selectedDocumentID }
    }

    public func isTemporary(_ document: WorkbenchDocument) -> Bool {
        temporaryDocumentID == document.id
    }

    public func pinTab(_ document: WorkbenchDocument) {
        if temporaryDocumentID == document.id {
            temporaryDocumentID = nil
        }
    }

    public func selectDocument(_ documentID: UUID, recordHistory: Bool = true) {
        guard documents.contains(where: { $0.id == documentID }) else { return }
        selectedDocumentID = documentID
        if recordHistory {
            tabHistory.recordSelection(documentID)
        }
    }

    public func goBackInTabHistory() -> UUID? {
        guard let id = tabHistory.goBack() else { return nil }
        guard documents.contains(where: { $0.id == id }) else {
            tabHistory.remove(documentID: id)
            return goBackInTabHistory()
        }
        tabHistory.navigate(to: id)
        selectedDocumentID = id
        return id
    }

    public func goForwardInTabHistory() -> UUID? {
        guard let id = tabHistory.goForward() else { return nil }
        guard documents.contains(where: { $0.id == id }) else {
            tabHistory.remove(documentID: id)
            return goForwardInTabHistory()
        }
        tabHistory.navigate(to: id)
        selectedDocumentID = id
        return id
    }

    @discardableResult
    public func openDocument(_ document: WorkbenchDocument, asTemporary: Bool = false) -> WorkbenchDocument {
        if let existing = documents.first(where: { $0.id == document.id }) {
            selectDocument(existing.id)
            if !asTemporary {
                pinTab(existing)
            }
            return existing
        }

        if let url = document.url,
           let existing = documents.first(where: { $0.url == url }) {
            selectDocument(existing.id)
            if !asTemporary {
                pinTab(existing)
            }
            return existing
        }

        if asTemporary,
           let tempID = temporaryDocumentID,
           let index = documents.firstIndex(where: { $0.id == tempID }),
           !documents[index].isDirty {
            let slot = documents[index]
            slot.url = document.url
            slot.displayName = document.displayName
            slot.text = document.text
            slot.language = document.language
            slot.languageIdentifier = document.languageIdentifier
            slot.isDirty = false
            slot.selectedRange = document.selectedRange
            slot.scrollOffset = document.scrollOffset
            slot.pendingState = document.pendingState
            slot.isFileBacked = document.isFileBacked
            slot.rangeReader = document.rangeReader
            temporaryDocumentID = slot.id
            selectDocument(slot.id)
            return slot
        }

        insertDocument(document, asTemporary: asTemporary)
        return document
    }

    public func insertDocument(_ document: WorkbenchDocument, asTemporary: Bool = false) {
        if let selectedDocumentID,
           let index = documents.firstIndex(where: { $0.id == selectedDocumentID }) {
            documents.insert(document, at: index + 1)
        } else {
            documents.append(document)
        }
        if asTemporary {
            temporaryDocumentID = document.id
        } else {
            pinTab(document)
        }
        selectDocument(document.id)
    }

    public func closeDocument(_ documentID: UUID) {
        let countBefore = documents.count
        let closingIndex = documents.firstIndex(where: { $0.id == documentID })
        let selectedIndex = selectedDocumentID.flatMap { id in
            documents.firstIndex(where: { $0.id == id })
        }
        let wasSelected = selectedDocumentID == documentID

        tabHistory.remove(documentID: documentID)
        if temporaryDocumentID == documentID {
            temporaryDocumentID = nil
        }
        documents.removeAll { $0.id == documentID }

        if wasSelected {
            if let closingIndex, let selectedIndex,
               let newIndex = TabListEngine.selectionIndexAfterClose(
                   closing: closingIndex,
                   selected: selectedIndex,
                   count: countBefore
               ),
               documents.indices.contains(newIndex) {
                selectedDocumentID = documents[newIndex].id
            } else {
                selectedDocumentID = documents.last?.id
            }
        }
    }
}
