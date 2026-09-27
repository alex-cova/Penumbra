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

public typealias UIResponder = NSResponder
