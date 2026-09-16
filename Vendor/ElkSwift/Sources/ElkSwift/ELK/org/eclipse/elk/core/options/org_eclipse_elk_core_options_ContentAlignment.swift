import Foundation

/**
 * Determines how the content of compound nodes is to be aligned if the compound node's size exceeds
 * the bounding box of the content (i.e. child nodes). This might be the case if for a compound node
 * the `SizeConstraint` of `SizeConstraint.MINIMUM_SIZE` is set and
 * `LayeredOptions.MIN_WIDTH` and `LayeredOptions.MIN_HEIGHT` are set large enough.
 *
 * <p>This property is to be used as an `OptionSet`; it should be comprised of
 * exactly one value prefixed with `V_` and one prefixed with `H_`.</p>
 *
 * <p>Default values are `ContentAlignment.V.top` and `ContentAlignment.H.left`.</p>
 */
package struct ContentAlignment: OptionSet, Hashable {
    package let rawValue: Int
    
    package init(rawValue: Int) {
        self.rawValue = rawValue
    }
    
    // Vertical alignment options
    package static let vTop = ContentAlignment(rawValue: 1 << 0)
    package static let vCenter = ContentAlignment(rawValue: 1 << 1)
    package static let vBottom = ContentAlignment(rawValue: 1 << 2)
    
    // Horizontal alignment options
    package static let hLeft = ContentAlignment(rawValue: 1 << 4)
    package static let hCenter = ContentAlignment(rawValue: 1 << 5)
    package static let hRight = ContentAlignment(rawValue: 1 << 6)
    
    // Convenience properties for vertical and horizontal components
    package var vertical: ContentAlignment {
        ContentAlignment(rawValue: self.rawValue & 0b0111)
    }
    
    package var horizontal: ContentAlignment {
        ContentAlignment(rawValue: self.rawValue & 0b1110000)
    }
    
    /**
     * @return a set containing `vCenter` and `hCenter`.
     */
    package static func centerCenter() -> ContentAlignment {
        [.vCenter, .hCenter]
    }
    
    /**
     * @return a set containing `vTop` and `hLeft`.
     */
    package static func topLeft() -> ContentAlignment {
        [.vTop, .hLeft]
    }
    
    /**
     * @return a set containing `vBottom` and `hRight`.
     */
    package static func bottomRight() -> ContentAlignment {
        [.vBottom, .hRight]
    }
    
    /**
     * @return a set containing `vTop` and `hCenter`.
     */
    package static func topCenter() -> ContentAlignment {
        [.vTop, .hCenter]
    }
}

// MARK: - CustomStringConvertible
extension ContentAlignment: CustomStringConvertible {
    package var description: String {
        var parts: [String] = []
        
        if contains(.vTop) { parts.append("V_TOP") }
        if contains(.vCenter) { parts.append("V_CENTER") }
        if contains(.vBottom) { parts.append("V_BOTTOM") }

        if contains(.hLeft) { parts.append("H_LEFT") }
        if contains(.hCenter) { parts.append("H_CENTER") }
        if contains(.hRight) { parts.append("H_RIGHT") }
        
        return parts.isEmpty ? "[]" : "{\(parts.joined(separator: ", "))}"
    }
}
