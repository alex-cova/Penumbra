import Foundation
@preconcurrency import AppKit

/// How matching bracket pairs are emphasized in the editor.
public enum BracketPairEmphasis: Equatable {
    case bordered(color: NSColor)
    /// Xcode-style flash on the opposite bracket only.
    case flash
    case underline(color: NSColor)

    var emphasizesSourceBracket: Bool {
        switch self {
        case .bordered, .underline:
            return true
        case .flash:
            return false
        }
    }
}
