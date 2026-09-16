import Foundation

/**
 * A cell which manages the size and placement of labels.
 */
package class LabelCell: Cell {

    // MARK: - Properties

    package let horizontalLayoutMode: Bool
    package var horizontalAlignment: HorizontalLabelAlignment = .center
    package var verticalAlignment: VerticalLabelAlignment = .center
    package let gap: Double
    package var labels: [LabelAdapter] = []
    package var minimumContentAreaSize = KVector()

    // MARK: - Computed properties for min width/height

    package var minimumWidth: Double { return getMinimumWidth() }
    package var minimumHeight: Double { return getMinimumHeight() }

    // MARK: - Constructors

    package init(gap: Double) {
        self.gap = gap
        self.horizontalLayoutMode = true
        super.init()
    }

    package init(gap: Double, horizontalLayoutMode: Bool) {
        self.gap = gap
        self.horizontalLayoutMode = horizontalLayoutMode
        super.init()
    }

    package convenience init(gap: Double, nodeLabelLocation: NodeLabelLocation) {
        self.init(gap: gap, nodeLabelLocation: nodeLabelLocation, horizontalLayoutMode: true)
    }

    package init(gap: Double, nodeLabelLocation: NodeLabelLocation, horizontalLayoutMode: Bool) {
        self.gap = gap
        self.horizontalLayoutMode = horizontalLayoutMode
        super.init()
        self.horizontalAlignment = nodeLabelLocation.horizontalAlignment
        self.verticalAlignment = nodeLabelLocation.verticalAlignment
    }

    /// Convenience init with labelLabelSpacing label
    package convenience init(labelLabelSpacing: Double) {
        self.init(gap: labelLabelSpacing)
    }

    // MARK: - Getters / Setters

    package func getHorizontalAlignment() -> HorizontalLabelAlignment {
        return horizontalAlignment
    }

    @discardableResult
    package func setHorizontalAlignment(_ newHorizontalAlignment: HorizontalLabelAlignment) -> LabelCell {
        self.horizontalAlignment = newHorizontalAlignment
        return self
    }

    package func getVerticalAlignment() -> VerticalLabelAlignment {
        return verticalAlignment
    }

    @discardableResult
    package func setVerticalAlignment(_ newVerticalAlignment: VerticalLabelAlignment) -> LabelCell {
        self.verticalAlignment = newVerticalAlignment
        return self
    }

    package func getLabels() -> [LabelAdapter] {
        return labels
    }

    // MARK: - Cell

    package override func getMinimumWidth() -> Double {
        let padding = getPadding()
        return minimumContentAreaSize.x + padding.left + padding.right
    }

    package override func getMinimumHeight() -> Double {
        let padding = getPadding()
        return minimumContentAreaSize.y + padding.top + padding.bottom
    }

    // MARK: - Adding Labels

    package func addLabel(_ label: LabelAdapter) {
        labels.append(label)

        let labelSize = label.getSize()

        if horizontalLayoutMode {
            minimumContentAreaSize.x = max(minimumContentAreaSize.x, labelSize.x)
            minimumContentAreaSize.y += labelSize.y

            if labels.count > 1 {
                minimumContentAreaSize.y += gap
            }
        } else {
            minimumContentAreaSize.x += labelSize.x
            minimumContentAreaSize.y = max(minimumContentAreaSize.y, labelSize.y)

            if labels.count > 1 {
                minimumContentAreaSize.x += gap
            }
        }
    }

    package func hasLabels() -> Bool {
        return !labels.isEmpty
    }

    // MARK: - Label Layout

    package func applyLabelLayout() {
        if horizontalLayoutMode {
            applyHorizontalModeLabelLayout()
        } else {
            applyVerticalModeLabelLayout()
        }
    }

    package func applyHorizontalModeLabelLayout() {
        let cellRect = getCellRectangle()
        let cellPadding = getPadding()

        var yPos = cellRect.y

        if verticalAlignment == .center {
            yPos += (cellRect.height - minimumContentAreaSize.y) / 2
        } else if verticalAlignment == .bottom {
            yPos += cellRect.height - minimumContentAreaSize.y
        }

        for label in labels {
            let labelSize = label.getSize()
            let labelPos = KVector()

            labelPos.y = yPos
            yPos += labelSize.y + gap

            switch horizontalAlignment {
            case .left:
                labelPos.x = cellRect.x + cellPadding.left
            case .center:
                labelPos.x = cellRect.x + cellPadding.left + (cellRect.width - labelSize.x) / 2
            case .right:
                labelPos.x = cellRect.x + cellRect.width - cellPadding.right - labelSize.x
            }

            label.setPosition(labelPos)
        }
    }

    package func applyVerticalModeLabelLayout() {
        let cellRect = getCellRectangle()
        let cellPadding = getPadding()

        var xPos = cellRect.x

        if horizontalAlignment == .center {
            xPos += (cellRect.width - minimumContentAreaSize.x) / 2
        } else if horizontalAlignment == .right {
            xPos += cellRect.width - minimumContentAreaSize.x
        }

        for label in labels {
            let labelSize = label.getSize()
            let labelPos = KVector()

            labelPos.x = xPos
            xPos += labelSize.x + gap

            switch verticalAlignment {
            case .top:
                labelPos.y = cellRect.y + cellPadding.top
            case .center:
                labelPos.y = cellRect.y + cellPadding.top + (cellRect.height - labelSize.y) / 2
            case .bottom:
                labelPos.y = cellRect.y + cellRect.height - cellPadding.bottom - labelSize.y
            }

            label.setPosition(labelPos)
        }
    }
}
