import Foundation
@preconcurrency import AppKit

/// Severity of a diagnostic shown in the text view.
public enum TextViewDiagnosticSeverity: Equatable, Sendable {
    case error
    case warning
    case information
    case hint

    var squiggleColor: NSColor {
        switch self {
        case .error:
            return NSColor.systemRed
        case .warning:
            return NSColor.systemOrange
        case .information:
            return NSColor.systemBlue
        case .hint:
            return NSColor.secondaryLabelColor
        }
    }
}
