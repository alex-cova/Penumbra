/**
 * Classes implementing this protocol know how to remove overlaps between a strip of rectangles.
 * 
 * @see RectangleStripOverlapRemover
 */
package protocol IRectangleStripOverlapRemovalStrategy {
    
    /**
     * Removes overlaps for the given {@link RectangleStripOverlapRemover}.
     * 
     * @param overlapRemover
     *            the overlap remover that invokes overlap removal.
     * @return the height of the resulting strip of rectangles.
     */
    func removeOverlaps(_ overlapRemover: RectangleStripOverlapRemover) -> Double
}
