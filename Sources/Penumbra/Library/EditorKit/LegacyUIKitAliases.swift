@preconcurrency import AppKit

// Temporary UIKit-shaped aliases for source compatibility during the EditorKit migration.
// Phase 4 removes these from the public API.

@available(*, deprecated, renamed: "EditorView")
public typealias UIView = EditorView

@available(*, deprecated, renamed: "EditorScrollView")
public typealias UIScrollView = EditorScrollView

@available(*, deprecated, renamed: "EditorLabel")
public typealias UILabel = EditorLabel

@available(*, deprecated, renamed: "EditorGestureRecognizer")
public typealias UIGestureRecognizer = EditorGestureRecognizer

@available(*, deprecated, renamed: "EditorGestureRecognizerDelegate")
public typealias UIGestureRecognizerDelegate = EditorGestureRecognizerDelegate

@available(*, deprecated, renamed: "EditorGestureRecognizerState")
public typealias UIGestureRecognizerState = EditorGestureRecognizerState

@available(*, deprecated, renamed: "EditorTapGestureRecognizer")
public typealias UITapGestureRecognizer = EditorTapGestureRecognizer

@available(*, deprecated, renamed: "EditorQuickTapGestureRecognizer")
public typealias QuickTapGestureRecognizer = EditorQuickTapGestureRecognizer

@available(*, deprecated, renamed: "EditorPanGestureRecognizer")
public typealias UIPanGestureRecognizer = EditorPanGestureRecognizer

@available(*, deprecated, renamed: "EditorPasteboard")
public typealias UIPasteboard = EditorPasteboard

@available(*, deprecated, renamed: "EditorScreen")
public typealias UIScreen = EditorScreen

@available(*, deprecated, renamed: "EditorBezierPath")
public typealias UIBezierPath = EditorBezierPath

@available(*, deprecated, renamed: "EditorTextAutocorrectionType")
public typealias UITextAutocorrectionType = EditorTextAutocorrectionType

@available(*, deprecated, renamed: "EditorTextAutocapitalizationType")
public typealias UITextAutocapitalizationType = EditorTextAutocapitalizationType

@available(*, deprecated, renamed: "EditorTextSmartQuotesType")
public typealias UITextSmartQuotesType = EditorTextSmartQuotesType

@available(*, deprecated, renamed: "EditorTextSmartDashesType")
public typealias UITextSmartDashesType = EditorTextSmartDashesType

@available(*, deprecated, renamed: "EditorTextSmartInsertDeleteType")
public typealias UITextSmartInsertDeleteType = EditorTextSmartInsertDeleteType

@available(*, deprecated, renamed: "EditorTextSpellCheckingType")
public typealias UITextSpellCheckingType = EditorTextSpellCheckingType

@available(*, deprecated, renamed: "EditorKeyboardType")
public typealias UIKeyboardType = EditorKeyboardType

@available(*, deprecated, renamed: "EditorKeyboardAppearance")
public typealias UIKeyboardAppearance = EditorKeyboardAppearance

@available(*, deprecated, renamed: "EditorReturnKeyType")
public typealias UIReturnKeyType = EditorReturnKeyType

@available(*, deprecated, renamed: "EditorTextGranularity")
public typealias UITextGranularity = EditorTextGranularity

@available(*, deprecated, renamed: "EditorTextDirection")
public typealias UITextDirection = EditorTextDirection

@available(*, deprecated, renamed: "EditorTextLayoutDirection")
public typealias UITextLayoutDirection = EditorTextLayoutDirection

@available(*, deprecated, renamed: "EditorTextStorageDirection")
public typealias UITextStorageDirection = EditorTextStorageDirection

@available(*, deprecated, renamed: "EditorKeyboardHIDUsage")
public typealias UIKeyboardHIDUsage = EditorKeyboardHIDUsage

@available(*, deprecated, renamed: "EditorTextSearchOptions")
public typealias UITextSearchOptions = EditorTextSearchOptions

@available(*, deprecated, renamed: "EditorTextSearchFoundTextStyle")
public typealias UITextSearchFoundTextStyle = EditorTextSearchFoundTextStyle

@available(*, deprecated, renamed: "EditorTraitCollection")
public typealias UITraitCollection = EditorTraitCollection

@available(*, deprecated, renamed: "EditorTextInputAssistantItem")
public typealias UITextInputAssistantItem = EditorTextInputAssistantItem

@available(*, deprecated, renamed: "EditorPlatformEvent")
public typealias UIEvent = EditorPlatformEvent

@available(*, deprecated, renamed: "EditorPress")
public typealias UIPress = EditorPress

@available(*, deprecated, renamed: "EditorKey")
public typealias UIKey = EditorKey

@available(*, deprecated, renamed: "EditorPressesEvent")
public typealias UIPressesEvent = EditorPressesEvent

public typealias UIResponder = NSResponder
