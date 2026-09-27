@preconcurrency import AppKit
import Foundation

public final class EditorPasteboard: @unchecked Sendable {
    public static let general = EditorPasteboard()
    public var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }
    public var hasStrings: Bool {
        NSPasteboard.general.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.string.rawValue])
    }
}

public final class EditorScreen: @unchecked Sendable {
    public static let main = EditorScreen()
    public var scale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }
}
