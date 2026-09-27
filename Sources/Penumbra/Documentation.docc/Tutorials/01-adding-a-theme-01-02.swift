import AppKit

extension NSColor {
    struct Tomorrow {
        var background: NSColor {
            return .white
        }
        var selection: NSColor {
            return NSColor(red: 222 / 255, green: 222 / 255, blue: 222 / 255, alpha: 1)
        }
        var currentLine: NSColor {
            return NSColor(red: 242 / 255, green: 242 / 255, blue: 242 / 255, alpha: 1)
        }
        var foreground: NSColor {
            return NSColor(red: 96 / 255, green: 96 / 255, blue: 95 / 255, alpha: 1)
        }
        var comment: NSColor {
            return NSColor(red: 159 / 255, green: 161 / 255, blue: 158 / 255, alpha: 1)
        }
        var red: NSColor {
            return NSColor(red: 196 / 255, green: 74 / 255, blue: 62 / 255, alpha: 1)
        }
        var orange: NSColor {
            return NSColor(red: 236 / 255, green: 157 / 255, blue: 68 / 255, alpha: 1)
        }
        var yellow: NSColor {
            return NSColor(red: 232 / 255, green: 196 / 255, blue: 66 / 255, alpha: 1)
        }
        var green: NSColor {
            return NSColor(red: 136 / 255, green: 154 / 255, blue: 46 / 255, alpha: 1)
        }
        var aqua: NSColor {
            return NSColor(red: 100 / 255, green: 166 / 255, blue: 173 / 255, alpha: 1)
        }
        var blue: NSColor {
            return NSColor(red: 94 / 255, green: 133 / 255, blue: 184 / 255, alpha: 1)
        }
        var purple: NSColor {
            return NSColor(red: 149 / 255, green: 115 / 255, blue: 179 / 255, alpha: 1)
        }

        fileprivate init() {}
    }

    static let tomorrow = Tomorrow()
}
