/*******************************************************************************
 * Copyright (c) 2017 Kiel University and others.
 * 
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/

import Foundation

/**
 * A container cell contains other cells. How it contains them depends on the actual container cell. This package class
 * simply adds methods that allow clients to tell the container to lay out its children.
 * 
 * @see StripContainerCell
 * @see GridContainerCell
 */
package class ContainerCell: Cell {
    
    /**
     * Compute x coordinates and widths of children.
     */
    package func layoutChildrenHorizontally() {
        assertionFailure("Subclass must override")
    }

    /**
     * Compute y coordinates and heights of children.
     */
    package func layoutChildrenVertically() {
        assertionFailure("Subclass must override")
    }
    
    // MARK: - Utility Methods
    
    /**
     * Returns the minimum width of the given cell.
     * 
     * @param cell the cell whose minimum width to return.
     * @param respectContributionFlag if true, zero is returned for cells that don't have the width contribution flag set.
     * @return minimum width.
     */
    package static func minWidthOfCell(_ cell: Cell?, respectContributionFlag: Bool) -> Double {
        // If there's no cell, there's no minimum width
        guard let cell = cell else {
            return 0
        }
        
        // If the cell doesn't have its contribution flag activated, there's no minimum width
        if respectContributionFlag && !cell.isContributingToMinimumWidth() {
            return 0
        }
        
        // If the cell is an atomic cell with a content area of no width, there's no minimum width
        if let atomicCell = cell as? AtomicCell {
            if atomicCell.getMinimumContentAreaSize().x == 0 {
                return 0
            }
        }
        
        return cell.getMinimumWidth()
    }
    
    /**
     * Returns the minimum height of the given cell.
     * 
     * @param cell the cell whose minimum height to return.
     * @param respectContributionFlag if true, zero is returned for cells that don't have the height contribution flag set.
     * @return minimum height.
     */
    package static func minHeightOfCell(_ cell: Cell?, respectContributionFlag: Bool) -> Double {
        // If there's no cell, there's no minimum height
        guard let cell = cell else {
            return 0
        }
        
        // If the cell doesn't have its contribution flag activated, there's no minimum height
        if respectContributionFlag && !cell.isContributingToMinimumHeight() {
            return 0
        }
        
        // If the cell is an atomic cell with a content area of no height, there's no minimum height
        if let atomicCell = cell as? AtomicCell {
            if atomicCell.getMinimumContentAreaSize().y == 0 {
                return 0
            }
        }
        
        return cell.getMinimumHeight()
    }
    
    /**
     * Applies the given horizontal layout information to the given cell if it's not nil.
     * 
     * @param cell the cell to apply the layout information to.
     * @param x the cell's new x coordinate.
     * @param width the cell's new width.
     */
    package func applyHorizontalLayout(_ cell: Cell?, x: Double, width: Double) {
        guard let cell = cell else { return }

        let cellRect = cell.getCellRectangle()
        cellRect.x = x
        cellRect.width = width
    }
    
    /**
     * Applies the given vertical layout information to the given cell if it's not nil.
     * 
     * @param cell the cell to apply the layout information to.
     * @param y the cell's new y coordinate.
     * @param height the cell's new height.
     */
    package func applyVerticalLayout(_ cell: Cell?, y: Double, height: Double) {
        guard let cell = cell else { return }

        let cellRect = cell.getCellRectangle()
        cellRect.y = y
        cellRect.height = height
    }
}
