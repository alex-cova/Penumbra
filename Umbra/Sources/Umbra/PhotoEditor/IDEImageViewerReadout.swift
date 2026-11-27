import Penumbra
import SwiftUI

/// Live zoom readout for `IDEImageViewerToolbar`. The controller is an AppKit object that calls
/// back on the main actor; the readout bridges those callbacks into SwiftUI state.
@Observable
@MainActor
final class IDEImageViewerReadout {
    var percent: Int = 100
    var pixelSize: CGSize = .zero

    func update(controller: ImageViewerController) {
        percent = controller.zoomPercent
        pixelSize = controller.imagePixelSize
    }
}
