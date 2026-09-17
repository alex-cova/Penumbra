@preconcurrency import AppKit
import Foundation

public final class UIPasteboard: @unchecked Sendable {
    public static let general = UIPasteboard()
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

public final class UIScreen: @unchecked Sendable {
    public static let main = UIScreen()
    public var scale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }
}

public enum UIApplication {
    public static let didReceiveMemoryWarningNotification = Notification.Name("UIApplicationDidReceiveMemoryWarningNotification")
}
