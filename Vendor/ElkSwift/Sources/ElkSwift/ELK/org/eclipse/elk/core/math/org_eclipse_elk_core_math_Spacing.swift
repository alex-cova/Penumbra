import Foundation

/**
 * Stores the spacing of an object in `Double` precision.
 */
package class Spacing {

    /** The spacing from the top. */
    package var top: Double = 0.0
    /** The spacing from the bottom. */
    package var bottom: Double = 0.0
    /** The spacing from the left. */
    package var left: Double = 0.0
    /** The spacing from the right. */
    package var right: Double = 0.0

    package init() {}

    package init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    /// Positional init for subclass convenience
    package init(_ top: Double, _ right: Double, _ bottom: Double, _ left: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    package func set(_ spacing: Spacing) {
        self.set(spacing.top, spacing.right, spacing.bottom, spacing.left)
    }

    package func set(_ newTop: Double, _ newRight: Double, _ newBottom: Double, _ newLeft: Double) {
        self.top = newTop
        self.right = newRight
        self.bottom = newBottom
        self.left = newLeft
    }

    package func getTop() -> Double {
        return top
    }

    package func setTop(_ top: Double) {
        self.top = top
    }

    package func getRight() -> Double {
        return right
    }

    package func setRight(_ right: Double) {
        self.right = right
    }

    package func getBottom() -> Double {
        return bottom
    }

    package func setBottom(_ bottom: Double) {
        self.bottom = bottom
    }

    package func getLeft() -> Double {
        return left
    }

    package func setLeft(_ left: Double) {
        self.left = left
    }

    package func setLeftRight(_ val: Double) {
        self.left = val
        self.right = val
    }

    package func setTopBottom(_ val: Double) {
        self.top = val
        self.bottom = val
    }

    package func getHorizontal() -> Double {
        return self.left + self.right
    }

    /// Computed property alias for getHorizontal().
    package var horizontal: Double {
        return self.left + self.right
    }

    package func getVertical() -> Double {
        return self.top + self.bottom
    }

    /// Computed property alias for getVertical().
    package var vertical: Double {
        return self.top + self.bottom
    }

    @discardableResult
    package func copy(_ other: Spacing) -> Self {
        self.left = other.left
        self.right = other.right
        self.top = other.top
        self.bottom = other.bottom
        return self
    }

    @discardableResult
    package func add(_ other: Spacing) -> Self {
        self.left += other.left
        self.right += other.right
        self.top += other.top
        self.bottom += other.bottom
        return self
    }

    package func equals(_ other: Spacing) -> Bool {
        return self.top == other.top && self.bottom == other.bottom && self.left == other.left && self.right == other.right
    }

    package func toString() -> String {
        return "[top=\(top),left=\(left),bottom=\(bottom),right=\(right)]"
    }
}
