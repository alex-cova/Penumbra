import AppKit
import Penumbra
import SwiftUI

/// File actions for the image toolbar: copy the pixels, reveal the file, enter the photo editor.
/// Icon-only with text labels intact, so VoiceOver names every control.
struct IDEImageViewerFileActions: View {
    var controller: ImageViewerController?
    var documentURL: URL?
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Button("Copy Image", systemImage: "doc.on.doc", action: copyImage)
                .help("Copy image to clipboard")
                .disabled(controller?.currentImage == nil)

            Button("Reveal in Finder", systemImage: "folder", action: revealInFinder)
                .help("Reveal in Finder")
                .disabled(documentURL == nil)

            Divider().frame(height: Layout.dividerHeight)

            Button("Edit Photo", systemImage: "slider.horizontal.3", action: onEdit)
                .help("Edit this photo")
                .disabled(documentURL == nil)
        }
        .labelStyle(.iconOnly)
    }

    private func copyImage() {
        guard let image = controller?.currentImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func revealInFinder() {
        guard let documentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([documentURL])
    }
}

private enum Layout {
    static let dividerHeight: CGFloat = 16
}
