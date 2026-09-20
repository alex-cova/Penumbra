import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_loops_SelfHyperLoopLabels {

    package enum Alignment {
        case CENTER
        case LEFT
        case RIGHT
        case TOP
    }

    package var id: Int = 0

    private var lLabels: [LLabel] = []
    private let size = KVector()
    private let position = KVector()
    private let layoutDirection: Direction
    private let labelLabelSpacing: Double

    private var side: PortSide = .UNDEFINED
    private var alignment: Alignment = .CENTER
    private var alignmentReferenceSLPort: SelfLoopPort?

    package init(_ slLoop: SelfHyperLoop) {
        let lNode = slLoop.getSLHolder().getLNode()
        self.layoutDirection = lNode.getGraph()?.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .RIGHT
        self.labelLabelSpacing = LGraphUtil.getIndividualOrInherited(lNode, property: LayeredOptions.SPACING_LABEL_LABEL)
    }

    // MARK: - LLabel Access

    package func addLLabels(_ newLLabels: [LLabel]) {
        for newLLabel in newLLabels {
            lLabels.append(newLLabel)
            updateSize(newLLabel)
        }
    }

    package func getLLabels() -> [LLabel] {
        return lLabels
    }

    private func updateSize(_ newLLabel: LLabel) {
        let newLLabelSize = newLLabel.getSize()

        if layoutDirection.isHorizontal() {
            size.x = max(size.x, newLLabelSize.x)
            size.y += newLLabelSize.y
            if lLabels.count > 1 {
                size.y += labelLabelSpacing
            }
        } else {
            size.x += newLLabelSize.x
            size.y = max(size.y, newLLabelSize.y)
            if lLabels.count > 1 {
                size.x += labelLabelSpacing
            }
        }
    }

    package func applyLabelManagement(_ labelManager: ILabelManager?, _ targetWidth: Double) {
        let result = org_eclipse_elk_alg_layered_intermediate_LabelManagementProcessor.doManageLabels(
            labelManager, lLabels, targetWidth, labelLabelSpacing, layoutDirection.isVertical())
        _ = size.set(result)
    }

    package func applyPlacement(_ offset: KVector) {
        if layoutDirection.isHorizontal() {
            applyPlacementForHorizontalLayout(offset)
        } else {
            applyPlacementForVerticalLayout(offset)
        }
    }

    private func applyPlacementForHorizontalLayout(_ offset: KVector) {
        let x = position.x
        var y = position.y

        for lLabel in lLabels {
            let labelPos = lLabel.getPosition()

            if alignment == .LEFT || side == .EAST {
                labelPos.x = x
            } else if alignment == .RIGHT || side == .WEST {
                labelPos.x = x + size.x - lLabel.getSize().x
            } else {
                labelPos.x = x + (size.x - lLabel.getSize().x) / 2
            }

            labelPos.y = y
            _ = labelPos.add(offset)

            y += lLabel.getSize().y + labelLabelSpacing
        }
    }

    private func applyPlacementForVerticalLayout(_ offset: KVector) {
        var x = position.x
        let y = position.y

        for lLabel in lLabels {
            let labelPos = lLabel.getPosition()

            labelPos.x = x

            if side == .NORTH {
                labelPos.y = y + size.y - lLabel.getSize().y
            } else {
                labelPos.y = y
            }

            _ = labelPos.add(offset)

            x += lLabel.getSize().x + labelLabelSpacing
        }
    }

    // MARK: - Label Placement

    package func getSize() -> KVector {
        return size
    }

    package func getPosition() -> KVector {
        return position
    }

    package func getSide() -> PortSide {
        return side
    }

    package func setSide(_ side: PortSide) {
        self.side = side
    }

    package func getAlignment() -> Alignment {
        return alignment
    }

    package func setAlignment(_ alignment: Alignment) {
        self.alignment = alignment
    }

    package func getAlignmentReferenceSLPort() -> SelfLoopPort? {
        return alignmentReferenceSLPort
    }

    package func setAlignmentReferenceSLPort(_ port: SelfLoopPort?) {
        self.alignmentReferenceSLPort = port
    }
}
