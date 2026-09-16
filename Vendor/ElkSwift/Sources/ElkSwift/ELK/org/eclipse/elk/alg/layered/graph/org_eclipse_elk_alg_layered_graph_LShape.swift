
/**
 * Abstract superclass for `LGraphElement`s that can have a position and a size.
 */
package class LShape: LGraphElement {

    /** the current position of the element. */
    package var position: KVector = KVector()
    /** the size of the element. */
    package var size: KVector = KVector()

    /**
     * Returns the element's current position.
     */
    package func getPosition() -> KVector {
        return position
    }

    /**
     * Sets the element's position.
     */
    package func setPosition(_ pos: KVector) {
        self.position = pos
    }

    /**
     * Returns the element's current size.
     */
    package func getSize() -> KVector {
        return size
    }

    /**
     * Sets the element's size.
     */
    package func setSize(_ s: KVector) {
        self.size = s
    }
}
