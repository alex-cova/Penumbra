import AppKit
import CoreImage
import Foundation
import Penumbra

/// Photo-editor sessions for image tabs, mirroring the hex/diagram session stores: one session
/// per document id, created on entering edit mode, released when the document closes everywhere.
final class IDEPhotoSessionStore {
    private var sessions: [UUID: PhotoEditorSession] = [:]

    func session(for documentID: UUID) -> PhotoEditorSession? {
        sessions[documentID]
    }

    func adopt(_ session: PhotoEditorSession, for documentID: UUID) {
        sessions[documentID] = session
    }

    @discardableResult
    func removeSession(for documentID: UUID) -> PhotoEditorSession? {
        sessions.removeValue(forKey: documentID)
    }
}

extension IDEWorkspace {
    /// The photo-editor session for `document`, creating and opening it on the file on first use.
    /// The autosaved recipe is restored when one exists.
    func photoSession(for document: WorkbenchDocument) -> PhotoEditorSession? {
        guard let url = document.url else { return nil }
        if let existing = photoSessionStore.session(for: document.id) {
            return existing
        }
        let session = PhotoEditorSession()
        session.openDocument(at: url)
        photoSessionStore.adopt(session, for: document.id)
        return session
    }

    func isPhotoEditing(_ documentID: UUID) -> Bool {
        photoEditingDocuments.contains(documentID)
    }

    /// The pane's selected document for SwiftUI gates (photo toolbar, edit overlay).
    ///
    /// Reads `tabsByPane`, not just `workbench.layout`: the workbench tree is edited in place and
    /// is not observable, so a body that only reads it never re-runs on a tab switch — the tab bar
    /// (which reads the mirror) and the AppKit viewer (updated imperatively) move on while the
    /// gate stays stale. `tabsByPane` is republished by `refreshPresentation()` on every switch,
    /// so touching it subscribes the caller. The tree remains the authority for the document.
    func selectedTabDocument(in paneID: UUID) -> WorkbenchDocument? {
        let document = workbench.layout.findPane(id: paneID)?.selectedDocument
        // The mirror only judges when it knows this pane: before the first `refreshPresentation`
        // it doesn't, and the tree is all there is. Either way the mirror is touched, which is
        // what subscribes the caller to tab switches.
        if let tabs = tabsByPane[paneID] {
            guard tabs.contains(where: \.isSelected) else { return nil }
        }
        return document
    }

    func setPhotoEditing(_ editing: Bool, document: WorkbenchDocument) {
        if editing {
            guard photoSession(for: document) != nil else { return }
            photoEditingDocuments.insert(document.id)
        } else {
            photoEditingDocuments.remove(document.id)
        }
        refreshPresentation()
    }

    func closePhotoSession(_ documentID: UUID) {
        photoSessionStore.removeSession(for: documentID)?.releaseSource()
        photoEditingDocuments.remove(documentID)
    }

    /// The format to write when saving back to the tab's own file. RAW and formats without a
    /// round-trippable target are export-only.
    static func photoSaveFormat(for url: URL) -> PhotoExportFormat? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": .jpeg
        case "png": .png
        case "heic", "heif": .heic
        case "tif", "tiff": .tiff16
        default: nil
        }
    }

    /// Renders the session's recipe at full resolution and writes it back to the tab's file.
    /// External-change tracking ignores image paths, so the viewer is refreshed here instead.
    func savePhotoEdits(_ document: WorkbenchDocument) {
        guard let url = document.url,
              let session = photoSessionStore.session(for: document.id),
              let format = Self.photoSaveFormat(for: url) else {
            return
        }
        let quality = format == .png ? 1.0 : 0.92
        Task { @MainActor [weak self] in
            guard let self else { return }
            // `adjustments` is Sendable and safe to cross into the detached render; the
            // ImageIO metadata dictionary is not, so encoding stays on the main actor like
            // the reference `PhotoEditorSession.export`.
            let adjustments = session.adjustments
            let rendered: SendableCGImage? = await Task.detached(priority: .userInitiated) {
                let engine = PhotoRenderEngine()
                let ciFormat: CIFormat = format == .tiff16 ? .RGBA16 : .RGBA8
                guard let rendered = engine.renderFull(
                    sourceURL: url,
                    adjustments: adjustments,
                    format: ciFormat
                ) else {
                    return nil
                }
                return SendableCGImage(image: rendered)
            }.value
            let data: Data? = if let rendered {
                try? PhotoExportEngine.encode(
                    rendered.image,
                    format: format,
                    quality: quality,
                    sourceMetadata: session.sourceMetadata
                )
            } else {
                nil
            }
            guard let data else {
                self.presentError(PhotoExportError.encodeFailed)
                return
            }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                self.presentError(error)
                return
            }
            session.markSaved()
            self.refreshImageViewer(for: document)
            self.refreshPresentation()
        }
    }

    /// Re-reads the file into every pane showing `document`'s viewer (used after a save).
    func refreshImageViewer(for document: WorkbenchDocument) {
        guard let url = document.url else { return }
        for pane in workbench.panes where pane.selectedDocument === document {
            host(for: pane.id).imageViewerController.show(url: url)
        }
    }
}
