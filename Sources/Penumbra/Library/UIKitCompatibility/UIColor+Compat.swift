@preconcurrency import AppKit
import Foundation

extension NSColor {
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var tertiaryLabel: NSColor { .tertiaryLabelColor }
    static var systemFill: NSColor { .controlBackgroundColor }
    static var systemBackground: NSColor { .windowBackgroundColor }

    convenience init?(named name: String, in bundle: Bundle?, compatibleWith traitCollection: UITraitCollection?) {
        self.init(named: name)
    }
}
