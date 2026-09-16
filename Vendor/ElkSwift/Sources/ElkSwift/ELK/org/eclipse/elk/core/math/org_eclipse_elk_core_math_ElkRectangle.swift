import Foundation

/**
 * Class resembles basic functionality of `Rectangle2D`. This way it is possible
 * to avoid AWT dependencies in ELK Layered's code.
 */
package final class ElkRectangle: Hashable {
    
    /** The X coordinate of this `Rectangle`. */
    package var x: Double
    
    /** The Y coordinate of this `Rectangle`. */
    package var y: Double
    
    /** The width of this `Rectangle`. */
    package var width: Double
    
    /** The height of this `Rectangle`. */
    package var height: Double
    
    /**
     * Constructs a new `Rectangle`, initialized to location (0,&nbsp;0) and size
     * (0,&nbsp;0).
     */
    package init() {
        self.x = 0
        self.y = 0
        self.width = 0
        self.height = 0
    }
    
    /**
     * Constructs and initializes a `Rectangle` from the specified `Double`
     * coordinates.
     *
     * - Parameters:
     *   - x: the x coordinate of the upper-left corner of the newly constructed `Rectangle`
     *   - y: the y coordinate of the upper-left corner of the newly constructed `Rectangle`
     *   - w: the width of the newly constructed `Rectangle`
     *   - h: the height of the newly constructed `Rectangle`
     */
    package init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        self.x = x
        self.y = y
        self.width = w
        self.height = h
    }

    /// Convenience initializer with labeled parameters.
    package convenience init(x: Double, y: Double, width: Double, height: Double) {
        self.init(x, y, width, height)
    }
    
    /**
     * Constructs and initializes a `Rectangle` from the specified instance.
     *
     * - Parameter rect: the existing rectangle whose values to copy.
     */
    package init(_ rect: ElkRectangle) {
        self.x = rect.x
        self.y = rect.y
        self.width = rect.width
        self.height = rect.height
    }
    
    /**
     * Sets the location and size of this `Rectangle` to the specified `Double` values.
     *
     * - Parameters:
     *   - nx: the X coordinate of the upper-left corner of this `Rectangle`
     *   - ny: the Y coordinate of the upper-left corner of this `Rectangle`
     *   - nw: the width of this `Rectangle`
     *   - nh: the height of this `Rectangle`
     */
    package func setRect(_ nx: Double, _ ny: Double, _ nw: Double, _ nh: Double) {
        self.x = nx
        self.y = ny
        self.width = nw
        self.height = nh
    }
    
    /**
     * - Returns: the (x,y) position of this rectangle.
     */
    package func getPosition() -> KVector {
        return KVector(x, y)
    }
    
    /**
     * - Returns: the top left coordinate (x,y).
     */
    package func getTopLeft() -> KVector {
        return getPosition()
    }
    
    /**
     * - Returns: the top right coordinate (x+w,y).
     */
    package func getTopRight() -> KVector {
        return KVector(x + width, y)
    }
    
    /**
     * - Returns: the bottom left coordinate (x,y+h).
     */
    package func getBottomLeft() -> KVector {
        return KVector(x, y + height)
    }
    
    /**
     * - Returns: the bottom right coordinate (x+w,y+h).
     */
    package func getBottomRight() -> KVector {
        return KVector(x + width, y + height)
    }
    
    /**
     * - Returns: the center point of a rectangle.
     */
    package func getCenter() -> KVector {
        return KVector(x + width / 2, y + height / 2)
    }
    
    /**
     * Unions the receiver and the given `Rectangle` objects and puts the result into the
     * receiver.
     *
     * - Parameter other: the `Rectangle` to be combined with this instance
     */
    package func union(_ other: ElkRectangle) {
        var x1 = min(self.x, other.x)
        var y1 = min(self.y, other.y)
        var x2 = max(self.x + self.width, other.x + other.width)
        var y2 = max(self.y + self.height, other.y + other.height)
        
        if x2 < x1 {
            swap(&x1, &x2)
        }
        if y2 < y1 {
            swap(&y1, &y2)
        }
        
        setRect(x1, y1, x2 - x1, y2 - y1)
    }
    
    /**
     * Moves the rectangle by the given offset.
     *
     * - Parameter offset: the offset to move the rectangle by.
     */
    package func move(_ offset: KVector) {
        x += offset.x
        y += offset.y
    }

    /// Labeled overload for move(by:).
    package func move(by offset: KVector) {
        move(offset)
    }
    
    /// Computed origin for compatibility with code using `.origin.x` / `.origin.y`
    package var origin: KVector {
        get { return KVector(x, y) }
        set { x = newValue.x; y = newValue.y }
    }

    /// Alias for `origin` — compatibility with code using `.position`.
    package var position: KVector {
        get { return KVector(x, y) }
        set { x = newValue.x; y = newValue.y }
    }

    /// Computed size as KVector for compatibility with `.size.width` / `.size.height` style access
    package var size: KVector {
        get { return KVector(width, height) }
        set { width = newValue.x; height = newValue.y }
    }

    package var description: String {
        return "Rect[x=\(x),y=\(y),w=\(width),h=\(height)]"
    }
    
    package static func == (lhs: ElkRectangle, rhs: ElkRectangle) -> Bool {
        return lhs.x == rhs.x && lhs.y == rhs.y
            && lhs.width == rhs.width && lhs.height == rhs.height
    }
    
    package func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
        hasher.combine(width)
        hasher.combine(height)
    }
    
    /**
     * Returns the largest X coordinate of the rectangle in double precision.
     */
    package func getMaxX() -> Double {
        return x + width
    }
    
    /**
     * Returns the largest Y coordinate of the rectangle in double precision.
     */
    package func getMaxY() -> Double {
        return y + height
    }
    
    /**
     * Tests if the interior of this rect intersects the interior of a specified rect.
     *
     * - Parameter rect: the other rectangle.
     * - Returns: true if the rectangles intersect, false otherwise.
     */
    package func intersects(_ rect: ElkRectangle) -> Bool {
        let r1x1 = self.x
        let r1y1 = self.y
        let r1x2 = self.x + self.width
        let r1y2 = self.y + self.height
        
        let r2x1 = rect.x
        let r2y1 = rect.y
        let r2x2 = rect.x + rect.width
        let r2y2 = rect.y + rect.height
        
        return r1x1 < r2x2 && r1x2 > r2x1 && r1y2 > r2y1 && r1y1 < r2y2
    }
}

