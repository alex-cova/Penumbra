@preconcurrency import AppKit
import Foundation

public typealias UIColor = NSColor
public typealias UIFont = NSFont
public typealias UIFontDescriptor = NSFontDescriptor
public typealias UIEdgeInsets = NSEdgeInsets
public typealias UIRectCorner = RectCorner

extension NSEdgeInsets {
    public static var zero: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
}

extension NSEdgeInsets: @retroactive Equatable {
    public static func == (lhs: NSEdgeInsets, rhs: NSEdgeInsets) -> Bool {
        lhs.top == rhs.top && lhs.left == rhs.left && lhs.bottom == rhs.bottom && lhs.right == rhs.right
    }
}

public struct RectCorner: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let topLeft = RectCorner(rawValue: 1 << 0)
    public static let topRight = RectCorner(rawValue: 1 << 1)
    public static let bottomLeft = RectCorner(rawValue: 1 << 2)
    public static let bottomRight = RectCorner(rawValue: 1 << 3)
    public static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

public enum UITextAutocorrectionType: Int { case `default` = 0, no = 1, yes = 2 }
public enum UITextAutocapitalizationType: Int { case none = 0, words = 1, sentences = 2, allCharacters = 3 }
public enum UITextSmartQuotesType: Int { case `default` = 0, no = 1, yes = 2 }
public enum UITextSmartDashesType: Int { case `default` = 0, no = 1, yes = 2 }
public enum UITextSmartInsertDeleteType: Int { case `default` = 0, no = 1, yes = 2 }
public enum UITextSpellCheckingType: Int { case `default` = 0, no = 1, yes = 2 }
public enum UIKeyboardType: Int { case `default` = 0 }
public enum UIKeyboardAppearance: Int { case `default` = 0, dark = 1, light = 2 }
public enum UIReturnKeyType: Int { case `default` = 0, done = 9 }

public enum UITextGranularity: Int { case character = 0, word = 1, sentence = 2, paragraph = 3, line = 4 }
public enum UITextDirection: Int { case forward = 0, backward = 1 }

extension UITextDirection {
    public init(storageDirection: UITextStorageDirection) {
        self = storageDirection == .backward ? .backward : .forward
    }
}
public enum UITextLayoutDirection: Int { case left = 0, right = 1, up = 2, down = 3 }
public enum UITextStorageDirection: Int { case forward = 0, backward = 1 }

public enum UIKeyboardHIDUsage: UInt {
    case keyboardUpArrow = 0x4C
    case keyboardDownArrow = 0x4D
    case keyboardLeftArrow = 0x4E
    case keyboardRightArrow = 0x4F
    case keyboardEscape = 0x29
}

public struct UITextSearchOptions: Sendable {
    public enum WordMatchMethod: Sendable { case contains, startsWith, fullWord }
    public var wordMatchMethod: WordMatchMethod = .contains
    public var stringCompareOptions: NSString.CompareOptions = []
    public init() {}
}

public enum UITextSearchFoundTextStyle: Int { case standard = 0, highlighted = 1, found = 2 }

extension UITextSearchFoundTextStyle {
    static var normal: UITextSearchFoundTextStyle { .standard }
}

public final class UITraitCollection {
    public init() {}
    public func hasDifferentColorAppearance(comparedTo other: UITraitCollection?) -> Bool { false }
}

public final class UITextInputAssistantItem: NSObject {
    public var leadingBarButtonGroups: [Any] = []
    public var trailingBarButtonGroups: [Any] = []
}

public class UIEvent: NSObject {}
public final class UIPress: NSObject { public var key: UIKey? }
public final class UIKey: NSObject { public var keyCode: UIKeyboardHIDUsage = .keyboardEscape }
public final class UIPressesEvent: UIEvent {}
