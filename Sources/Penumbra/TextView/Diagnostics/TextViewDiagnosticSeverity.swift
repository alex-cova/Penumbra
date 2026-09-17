import Foundation
@preconcurrency import AppKit

/// Severity of a diagnostic shown in the text view.
public enum TextViewDiagnosticSeverity: Equatable, Sendable {
    case error
    case warning
    case information
    case hint

    var squiggleColor: UIColor {
        switch self {
        case .error:
            return UIColor.systemRed
        case .warning:
            return UIColor.systemOrange
        case .information:
            return UIColor.systemBlue
        case .hint:
            return UIColor.secondaryLabelColor
        }
    }
}
