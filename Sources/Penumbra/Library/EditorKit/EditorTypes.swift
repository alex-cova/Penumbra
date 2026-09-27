@preconcurrency import AppKit
import Foundation

extension NSEdgeInsets {
    public static var zero: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
}

extension NSEdgeInsets: @retroactive Equatable {
    public static func == (lhs: NSEdgeInsets, rhs: NSEdgeInsets) -> Bool {
        lhs.top == rhs.top && lhs.left == rhs.left && lhs.bottom == rhs.bottom && rhs.right == rhs.right
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

public enum EditorTextAutocorrectionType: Int { case `default` = 0, no = 1, yes = 2 }
public enum EditorTextAutocapitalizationType: Int { case none = 0, words = 1, sentences = 2, allCharacters = 3 }
public enum EditorTextSmartQuotesType: Int { case `default` = 0, no = 1, yes = 2 }
public enum EditorTextSmartDashesType: Int { case `default` = 0, no = 1, yes = 2 }
public enum EditorTextSmartInsertDeleteType: Int { case `default` = 0, no = 1, yes = 2 }
public enum EditorTextSpellCheckingType: Int { case `default` = 0, no = 1, yes = 2 }
public enum EditorKeyboardType: Int { case `default` = 0 }
public enum EditorKeyboardAppearance: Int { case `default` = 0, dark = 1, light = 2 }
public enum EditorReturnKeyType: Int { case `default` = 0, done = 9 }

public enum EditorTextGranularity: Int { case character = 0, word = 1, sentence = 2, paragraph = 3, line = 4 }
public enum EditorTextDirection: Int { case forward = 0, backward = 1 }

extension EditorTextDirection {
    public init(storageDirection: EditorTextStorageDirection) {
        self = storageDirection == .backward ? .backward : .forward
    }
}
public enum EditorTextLayoutDirection: Int { case left = 0, right = 1, up = 2, down = 3 }
public enum EditorTextStorageDirection: Int { case forward = 0, backward = 1 }

public enum EditorKeyboardHIDUsage: UInt {
    case keyboardUpArrow = 0x4C
    case keyboardDownArrow = 0x4D
    case keyboardLeftArrow = 0x4E
    case keyboardRightArrow = 0x4F
    case keyboardEscape = 0x29
}

public struct EditorTextSearchOptions: Sendable {
    public enum WordMatchMethod: Sendable { case contains, startsWith, fullWord }
    public var wordMatchMethod: WordMatchMethod = .contains
    public var stringCompareOptions: NSString.CompareOptions = []
    public init() {}
}

public enum EditorTextSearchFoundTextStyle: Int { case standard = 0, highlighted = 1, found = 2 }

extension EditorTextSearchFoundTextStyle {
    static var normal: EditorTextSearchFoundTextStyle { .standard }
}

public final class EditorTraitCollection {
    public init() {}
    public func hasDifferentColorAppearance(comparedTo other: EditorTraitCollection?) -> Bool { false }
}

public final class EditorTextInputAssistantItem: NSObject {
    public var leadingBarButtonGroups: [Any] = []
    public var trailingBarButtonGroups: [Any] = []
}

public class EditorPlatformEvent: NSObject {}
public final class EditorPress: NSObject { public var key: EditorKey? }
public final class EditorKey: NSObject { public var keyCode: EditorKeyboardHIDUsage = .keyboardEscape }
public final class EditorPressesEvent: EditorPlatformEvent {}
