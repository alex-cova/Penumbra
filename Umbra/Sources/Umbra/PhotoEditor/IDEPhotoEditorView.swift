import Penumbra
import SwiftUI

/// Edit-mode overlay for an image tab: the photo editor over the pane's viewer. The session is
/// owned by the workspace (one per document, restored from the autosave store on first use), so
/// switching tabs and coming back keeps the edits.
struct IDEPhotoEditorView: View {
    @Environment(IDEWorkspace.self) private var workspace
    let document: WorkbenchDocument

    @State private var showExportSheet = false
    @State private var exportError: String?

    private var session: PhotoEditorSession? {
        workspace.photoSessionStore.session(for: document.id)
    }

    var body: some View {
        Group {
            if let session {
                PhotoEditorWorkspace(
                    session: session,
                    canSave: canSave,
                    onSave: { workspace.savePhotoEdits(document) },
                    onExport: { showExportSheet = true },
                    onDone: { workspace.setPhotoEditing(false, document: document) }
                )
                .sheet(isPresented: $showExportSheet) {
                    PhotoExportSheet(session: session, exportError: $exportError)
                }
            } else if let url = document.url {
                VStack(spacing: IDEAppearance.Spacing.sm) {
                    Text("Could not open this image for editing.")
                        .font(IDEAppearance.Typography.caption)
                    Button("Back to Viewer") {
                        workspace.setPhotoEditing(false, document: document)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PhotoStudio.Photo.canvasVoid)
                .accessibilityLabel("Could not open \(url.lastPathComponent) for editing")
            }
        }
        .overlay(alignment: .top) {
            if let message = exportError ?? session?.loadError {
                Text(message)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .padding(.horizontal, IDEAppearance.Spacing.sm)
                    .padding(.vertical, IDEAppearance.Spacing.xs)
                    .background(IDEAppearance.ColorToken.panel, in: .rect(cornerRadius: 6))
                    .padding(.top, IDEAppearance.Spacing.sm)
            }
        }
    }

    private var canSave: Bool {
        guard let url = document.url else { return false }
        return IDEWorkspace.photoSaveFormat(for: url) != nil
    }
}
