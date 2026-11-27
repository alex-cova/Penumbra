import Penumbra
import SwiftUI

/// Toolbar over an image tab: the zoom cluster, then file actions. Shown above the viewer while
/// the pane's selected document is an image and the photo editor is not open.
///
/// Design: Umbra chrome (panel fill, caption type, muted secondary text), icon-only buttons whose
/// text labels stay intact for VoiceOver. Static by intent: the readout updates instantly on the
/// controller callback, with no entrance or transition animation.
struct IDEImageViewerToolbar: View {
    @Environment(IDEWorkspace.self) private var workspace
    let paneID: UUID

    @State private var readout = IDEImageViewerReadout()

    private var host: IDEEditorPaneHost? { workspace.hostCache.peek(paneID) }
    private var controller: ImageViewerController? { host?.imageViewerController }
    private var document: WorkbenchDocument? {
        workspace.selectedTabDocument(in: paneID)
    }

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            IDEImageViewerZoomCluster(
                controller: controller,
                percent: readout.percent,
                pixelSize: readout.pixelSize
            )

            Spacer(minLength: 0)

            IDEImageViewerFileActions(
                controller: controller,
                documentURL: document?.url,
                onEdit: enterEditMode
            )
        }
        .font(IDEAppearance.Typography.caption)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
        .background(IDEAppearance.ColorToken.panel)
        .onAppear(perform: attach)
        .onChange(of: document?.id) { _, _ in attach() }
    }

    private func enterEditMode() {
        guard let document else { return }
        workspace.setPhotoEditing(true, document: document)
    }

    private func attach() {
        guard let controller else { return }
        readout.update(controller: controller)
        controller.onStateChange = { [weak readout, weak controller] in
            Task { @MainActor in
                guard let readout, let controller else { return }
                readout.update(controller: controller)
            }
        }
    }
}
