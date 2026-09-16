import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_LabelManagementProcessor {

    package static let MIN_WIDTH_EDGE_LABELS: Double = 0

    package var placeAtCenter: Bool = false

    package init() {}

    package init(_ placeAtCenter: Bool) {
        self.placeAtCenter = placeAtCenter
    }

    /// Returns the size of the labels unchanged (stub — label management is not implemented).
    package static func doManageLabels(
        _ labelManager: ILabelManager?,
        _ labels: [LLabel],
        _ targetWidth: Double,
        _ labelLabelSpacing: Double,
        _ verticalLayout: Bool
    ) -> KVector {
        // Compute the size the same way SelfHyperLoopLabels.updateSize does
        let size = KVector()
        var first = true
        for label in labels {
            let ls = label.getSize()
            if verticalLayout {
                size.x += ls.x
                size.y = max(size.y, ls.y)
                if !first { size.x += labelLabelSpacing }
            } else {
                size.x = max(size.x, ls.x)
                size.y += ls.y
                if !first { size.y += labelLabelSpacing }
            }
            first = false
        }
        return size
    }
}
