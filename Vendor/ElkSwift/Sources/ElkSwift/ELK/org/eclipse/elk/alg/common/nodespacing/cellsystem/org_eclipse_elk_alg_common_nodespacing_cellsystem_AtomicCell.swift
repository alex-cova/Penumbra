import Foundation

/**
 * An atomic cell is a simple cell that simply holds a size. Its minimum size can be directly manipulated. This is
 * basically a placeholder for other things to be placed in the cell system later.
 */
package class AtomicCell: Cell {
    
    // MARK: - Properties
    
    /** The minimum size of a cell's content area (that is, this excludes the padding). */
    package var minimumContentAreaSize = KVector()
    
    // MARK: - Getters / Setters
    
    /**
     * Returns the minimum content area size, to be modified by clients. Note that this size does not include any
     * padding.
     */
    package func getMinimumContentAreaSize() -> KVector {
        return minimumContentAreaSize
    }
    
    /**
     * Sets the cell's minimum size.
     *
     * - Parameters:
     *   - newMinimumContentAreaSize: the new minimum content area size.
     *   - includesPadding: if `true`, the new size includes padding that needs to be subtracted.
     */
    package func setMinimumContentAreaSize(_ newMinimumContentAreaSize: KVector, includesPadding: Bool) {
        if includesPadding {
            let padding = getPadding()
            minimumContentAreaSize.x = newMinimumContentAreaSize.x - padding.left - padding.right
            minimumContentAreaSize.y = newMinimumContentAreaSize.y - padding.top - padding.bottom
        } else {
            minimumContentAreaSize = newMinimumContentAreaSize
        }
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
}
