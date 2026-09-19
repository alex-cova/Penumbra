import Foundation
// swiftlint:disable file_length type_body_length
@preconcurrency import AppKit
import CoreText
import EditorIntelligence
import simd

/// A single, non-blocking snapshot of Metal renderer counters.
public struct MetalPerformanceStats: Sendable {
    public let fragmentCount: Int
    public let glyphInstanceCount: Int
    public let solidInstanceCount: Int
    public let coverageAtlasBytes: Int
    public let colorAtlasBytes: Int
    public let drawNanosP95: Double
    public let rasterCapSkipCount: Int
    public let instanceRebuildNanos: Int
    public let decorationBuildCount: Int
    public let glyphBufferRebuildCount: Int
    public let solidBufferRebuildCount: Int
}

/// A type similiar to UITextView with features commonly found in code editors.
///
/// `TextView` is a performant implementation of a text view with features such as showing line numbers, searching for text and replacing results, syntax highlighting, showing invisible characters and more.
///
/// The type does not subclass `UITextView` but its interface is kept close to `UITextView`.
///
/// When initially configuring the `TextView` with a theme, a language and the text to be shown, it is recommended to use the ``setState(_:addUndoAction:)`` function.
    /// The function takes an instance of ``TextViewState`` as input which can be created on a background queue to avoid blocking the main queue while doing the initial parse of a text.
    /// Pass ``SyntaxParsePolicy/deferred`` to skip the parse during `TextViewState` construction entirely: the text view paints immediately and highlights once the background parse finishes.
    /// Pass ``SyntaxParsePolicy/viewport`` to parse only the visible window so a large file does not build a full-document tree.
    open class TextView: UIScrollView {
    /// Delegate to receive callbacks for events triggered by the editor.
    public weak var editorDelegate: TextViewDelegate?
    /// Optional handler invoked before default key handling. Return `true` to consume the event.
    public var keyDownHandler: ((NSEvent) -> Bool)?
    /// Keystroke → action bindings. Defaults to ``Keymap/default_`` (Penumbra's historical
    /// shortcuts). Assign ``Keymap/intelliJ`` for an IntelliJ-style set.
    public var keymap: Keymap = .default_ {
        didSet { textInputView.keymap = keymap }
    }
    /// Invoked for keymap actions the editor core does not perform itself (palette, LSP
    /// navigation, formatting, surround-with). Return `true` if handled. `EditorIntelligenceController`
    /// and the command-palette controller install handlers here.
    public var editorActionHandler: ((EditorActionID) -> Bool)?
    private var keyDownInterceptors: [(NSEvent) -> Bool] = []

    /// Registers an additional key-down interceptor. Interceptors run after ``keyDownHandler``,
    /// in registration order; the first to return `true` consumes the event. Unlike assigning
    /// ``keyDownHandler`` this composes, so several features (completion, command palette) can
    /// each observe keys.
    public func addKeyDownInterceptor(_ interceptor: @escaping (NSEvent) -> Bool) {
        keyDownInterceptors.append(interceptor)
    }
    /// Whether the text view is in a state where the contents can be edited.
    public private(set) var isEditing = false {
        didSet {
            if isEditing != oldValue {
                textInputView.isEditing = isEditing
            }
        }
    }
    /// The text that the text view displays.
    public var text: String {
        get {
            textInputView.string as String
        }
        set {
            textInputView.string = newValue as NSString
            // Never mutate contentSize synchronously — Hextech assigns text from
            // updateNSView; scrolling document frame mid-pass aborts AppKit.
            hasPendingContentSizeUpdate = true
            setNeedsLayout()
        }
    }
    /// Whether the live buffer is a file-backed piece tree rather than a contiguous `NSMutableString`.
    public var isFileBacked: Bool {
        textInputView.isFileBacked
    }
    /// UTF-16 length of the document without materializing ``text``.
    public var documentLength: Int {
        textInputView.documentLength
    }
    /// Number of lines in the document (including a trailing empty line after a final newline).
    public var lineCount: Int {
        textInputView.lineManager.lineCount
    }

    func pieceTreeContentSnapshot() -> PieceTreeContentSnapshot? {
        textInputView.stringView.contentSnapshot()
    }

    /// Sendable document view for ``FindSearchEngine``. File-backed buffers return a piece-tree
    /// snapshot and do not materialize UTF-16.
    public func makeFindTextSource() -> any FindTextSource {
        if let snapshot = textInputView.stringView.contentSnapshot() {
            return snapshot
        }
        return StringFindTextSource(textInputView.string as String)
    }

    /// Bumped on every mutation of the live buffer. Hosts can compare this across tab switches
    /// to detect edits without reading ``text`` (which materializes file-backed documents).
    public var contentGeneration: UInt64 {
        textInputView.stringView.contentGeneration
    }

    var stringViewObjectIdentifier: ObjectIdentifier {
        ObjectIdentifier(textInputView.stringView)
    }
    /// A Boolean value that indicates whether the text view is editable.
    public var isEditable = true {
        didSet {
            if isEditable != oldValue && !isEditable && isEditing {
                resignFirstResponder()
                textInputViewDidEndEditing(textInputView)
            }
        }
    }
    /// A Boolean value that indicates whether the text view is selectable.
    public var isSelectable = true {
        didSet {
            if isSelectable != oldValue {
                textInputView.isUserInteractionEnabled = isSelectable
                if !isSelectable && isEditing {
                    resignFirstResponder()
                    textInputView.clearSelection()
                    textInputViewDidEndEditing(textInputView)
                }
            }
        }
    }
    /// Colors and fonts to be used by the editor.
    public var theme: Theme {
        get {
            textInputView.theme
        }
        set {
            textInputView.theme = newValue
            minimapView.applyTheme()
            scrollerOverlay.applyTheme()
            findPanelController.panelView.apply(theme: newValue)
        }
    }
    /// The autocorrection style for the text view.
    public var autocorrectionType: UITextAutocorrectionType {
        get {
            textInputView.autocorrectionType
        }
        set {
            textInputView.autocorrectionType = newValue
        }
    }
    /// The autocapitalization style for the text view.
    public var autocapitalizationType: UITextAutocapitalizationType {
        get {
            textInputView.autocapitalizationType
        }
        set {
            textInputView.autocapitalizationType = newValue
        }
    }
    /// The spell-checking style for the text view.
    public var smartQuotesType: UITextSmartQuotesType {
        get {
            textInputView.smartQuotesType
        }
        set {
            textInputView.smartQuotesType = newValue
        }
    }
    /// The configuration state for smart dashes.
    public var smartDashesType: UITextSmartDashesType {
        get {
            textInputView.smartDashesType
        }
        set {
            textInputView.smartDashesType = newValue
        }
    }
    /// The configuration state for the smart insertion and deletion of space characters.
    public var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get {
            textInputView.smartInsertDeleteType
        }
        set {
            textInputView.smartInsertDeleteType = newValue
        }
    }
    /// The spell-checking style for the text object.
    public var spellCheckingType: UITextSpellCheckingType {
        get {
            textInputView.spellCheckingType
        }
        set {
            textInputView.spellCheckingType = newValue
        }
    }
    /// The keyboard type for the text view.
    public var keyboardType: UIKeyboardType {
        get {
            textInputView.keyboardType
        }
        set {
            textInputView.keyboardType = newValue
        }
    }
    /// The appearance style of the keyboard for the text view.
    public var keyboardAppearance: UIKeyboardAppearance {
        get {
            textInputView.keyboardAppearance
        }
        set {
            textInputView.keyboardAppearance = newValue
        }
    }
    /// The display of the return key.
    public var returnKeyType: UIReturnKeyType {
        get {
            textInputView.returnKeyType
        }
        set {
            textInputView.returnKeyType = newValue
        }
    }
    /// Returns the undo manager used by the text view.
    override public var undoManager: UndoManager? {
        textInputView.undoManager
    }
    /// The color of the insertion point. This can be used to control the color of the caret.
    public var insertionPointColor: UIColor {
        get {
            textInputView.insertionPointColor
        }
        set {
            textInputView.insertionPointColor = newValue
        }
    }
    /// The color of the selection bar. It is most common to set this to the same color as the color used for the insertion point.
    public var selectionBarColor: UIColor {
        get {
            textInputView.selectionBarColor
        }
        set {
            textInputView.selectionBarColor = newValue
        }
    }
    /// The color of the selection highlight. It is most common to set this to the same color as the color used for the insertion point.
    public var selectionHighlightColor: UIColor {
        get {
            textInputView.selectionHighlightColor
        }
        set {
            textInputView.selectionHighlightColor = newValue
        }
    }
    /// The current selection range of the text view.
    public var selectedRange: NSRange {
        get {
            if let selectedRange = textInputView.selection {
                return selectedRange
            } else {
                // UITextView returns the end of the document for the selectedRange by default.
                return NSRange(location: textInputView.string.length, length: 0)
            }
        }
        set {
            textInputView.selectedTextRange = IndexedRange(newValue)
        }
    }
    /// All active selection ranges. Multiple zero-length ranges indicate multi-cursor mode.
    public var selectedRanges: [NSRange] {
        get {
            textInputView.selectedRanges
        }
        set {
            textInputView.selectedRanges = newValue
        }
    }
    /// Whether the text view currently has multiple carets.
    public var isMultiCursorActive: Bool {
        textInputView.isMultiCursorActive
    }
    /// Collapses multiple carets down to the primary caret.
    public func collapseMultiSelectionToPrimary() {
        textInputView.collapseMultiSelectionToPrimary()
    }
    /// Adds a caret at the beginning of each line spanned by the current selection.
    public func addSelectionsOnEachLine() {
        textInputView.addSelectionsOnEachLine()
    }
    /// Selects the word at the caret, or adds the next matching occurrence to the selection (⌘D).
    public func selectNextOccurrence() {
        textInputView.selectNextOccurrence()
    }
    /// Replaces the most recently added occurrence range with the next match after it, rather
    /// than appending (⌘K ⌘D) — skip a match you don't want without losing the ones already
    /// selected. No-op with fewer than two selected ranges.
    public func skipCurrentOccurrence() {
        textInputView.skipCurrentOccurrence()
    }
    /// Selects every occurrence of the current query in the document (⌘⇧L). If the selection is
    /// empty, the word under the caret becomes the query first.
    public func selectAllOccurrences() {
        textInputView.selectAllOccurrences()
    }
    /// Adds a new caret one visual line above the topmost caret (⌥⌘↑).
    public func addCaretAbove() {
        textInputView.addCaretAbove()
    }
    /// Adds a new caret one visual line below the bottommost caret (⌥⌘↓).
    public func addCaretBelow() {
        textInputView.addCaretBelow()
    }
    /// Steps the caret set back to what it was before the most recent additive multi-caret
    /// operation (⌘U) — e.g. undoes the last `selectNextOccurrence()`, `addCaretAbove()`, or
    /// Option-click. This is independent of the document's text undo stack.
    public func undoLastCaretChange() {
        textInputView.undoLastCaretChange()
    }
    /// Whether a column/block selection is currently active.
    public var isBlockSelectionActive: Bool {
        textInputView.blockSelectionController.isActive
    }
    /// Starts a column/block selection anchored at `point` (view coordinates).
    public func beginBlockSelection(at point: CGPoint) {
        textInputView.beginBlockSelection(at: point)
    }
    /// Extends the active block selection's far corner to `point` (view coordinates). Starts a
    /// new block selection at the current caret if one isn't already active.
    public func extendBlockSelection(to point: CGPoint) {
        textInputView.extendBlockSelection(to: point)
    }
    /// Ends block-selection mode without changing the current selection.
    public func endBlockSelection() {
        textInputView.endBlockSelection()
    }
    /// Whether sticky column (block) selection mode is on (⌘⇧8). While on, the block rectangle
    /// survives ordinary selection assignment and grows with plain arrow keys.
    public var isColumnSelectionModeEnabled: Bool {
        textInputView.blockSelectionController.isStickyModeEnabled
    }
    /// Toggles sticky column selection mode.
    public func toggleColumnSelectionMode() {
        textInputView.toggleColumnSelectionMode()
    }
    /// Replaces, at every selected range, the range beginning `relativeStartOffset` UTF-16 units
    /// from that selection's own start and extending `length` units — the same relative edit
    /// applied identically at every caret. Used to apply a completion (or similar) at every
    /// multi-cursor site once its replacement range relative to the primary caret is known.
    /// No-op when only one selection is active — callers should use `replace(_:withText:)` there.
    public func replaceAtAllSelections(relativeStartOffset: Int, length: Int, with text: String) {
        textInputView.replaceAtAllSelections(relativeStartOffset: relativeStartOffset, length: length, with: text)
    }
    /// The current selection range of the text view as a UITextRange.
    public var selectedTextRange: UITextRange? {
        get {
            textInputView.selectedTextRange
        }
        set {
            textInputView.selectedTextRange = newValue
        }
    }
    /// The custom input accessory view to display when the receiver becomes the first responder.
    public override var inputAccessoryView: UIView? {
        get {
            if isInputAccessoryViewEnabled {
                return _inputAccessoryView
            } else {
                return nil
            }
        }
        set {
            _inputAccessoryView = newValue
        }
    }
    /// The input assistant to use when configuring the keyboard's shortcuts bar.
    public override var inputAssistantItem: UITextInputAssistantItem {
        textInputView.inputAssistantItem
    }
    /// Returns a Boolean value indicating whether this object can become the first responder.
    var canBecomeFirstResponder: Bool {
        !textInputView.isFirstResponder && isEditable
    }
    /// The text view's background color.
    public override var backgroundColor: UIColor? {
        get {
            textInputView.backgroundColor
        }
        set {
            super.backgroundColor = newValue
            textInputView.backgroundColor = newValue
        }
    }
    /// The point at which the origin of the content view is offset from the origin of the scroll view.
    override public var contentOffset: CGPoint {
        get { super.contentOffset }
        set {
            let oldValue = super.contentOffset
            super.contentOffset = newValue
            guard newValue != oldValue else {
                return
            }
            textInputView.viewport = CGRect(origin: newValue, size: frame.size)
            // Scroll-wheel updates contentOffset without going through AppKit's
            // layout pass — force line layout for the new viewport now or the
            // clip view reveals empty document space ("text disappears").
            textInputView.layoutIfNeeded()
            textInputView.ensureViewportSyntaxParse()
        }
    }
    /// Character pairs are used by the editor to automatically insert a trailing character when the user types the leading character.
    ///
    /// Common usages of this includes the \" character to surround strings and { } to surround a scope.
    public var characterPairs: [CharacterPair] {
        get {
            textInputView.characterPairs
        }
        set {
            textInputView.characterPairs = newValue
        }
    }
    /// Determines what should happen to the trailing component of a character pair when deleting the leading component. Defaults to `disabled` meaning that nothing will happen.
    public var characterPairTrailingComponentDeletionMode: CharacterPairTrailingComponentDeletionMode {
        get {
            textInputView.characterPairTrailingComponentDeletionMode
        }
        set {
            textInputView.characterPairTrailingComponentDeletionMode = newValue
        }
    }
    /// Enable to show line numbers in the gutter.
    public var showLineNumbers: Bool {
        get {
            textInputView.showLineNumbers
        }
        set {
            textInputView.showLineNumbers = newValue
        }
    }

    /// Re-syncs gutter visibility and line-number layout after wholesale state changes.
    public func refreshGutterChrome() {
        textInputView.refreshGutterChrome()
    }

    /// Whether code folding is enabled. When on, a folding ribbon is shown in the gutter (using
    /// indentation to determine foldable regions) and collapsed regions are hidden — their lines
    /// simply take up zero height, so scrolling and hit-testing already skip them for free — with
    /// the header line of a collapsed region showing a "⋯" placeholder. Off by default.
    public var isLineFoldingEnabled: Bool {
        get {
            textInputView.isLineFoldingEnabled
        }
        set {
            textInputView.isLineFoldingEnabled = newValue
        }
    }
    /// Whether Focus Mode is enabled. When on, the sentence or paragraph (see
    /// ``focusGranularity``) containing the caret — or touched by the selection, with multiple
    /// cursors each keeping their own unit lit — stays at full opacity, while the rest of the
    /// document dims to ``unfocusedTextAlpha``. Off by default.
    public var isFocusModeEnabled: Bool {
        get {
            textInputView.isFocusModeEnabled
        }
        set {
            textInputView.isFocusModeEnabled = newValue
        }
    }
    /// The unit of text Focus Mode keeps focused. Defaults to ``FocusGranularity/paragraph``.
    public var focusGranularity: FocusGranularity {
        get {
            textInputView.focusGranularity
        }
        set {
            textInputView.focusGranularity = newValue
        }
    }
    /// Opacity applied to text outside the focused range while ``isFocusModeEnabled`` is on.
    /// Clamped to `0...1`. Defaults to `0.35`.
    public var unfocusedTextAlpha: CGFloat {
        get {
            textInputView.unfocusedTextAlpha
        }
        set {
            textInputView.unfocusedTextAlpha = newValue
        }
    }
    /// The document ranges Focus Mode currently keeps at full opacity. Empty when
    /// ``isFocusModeEnabled`` is off or the caret sits on a blank line.
    public var focusedRanges: [NSRange] {
        textInputView.focusedRanges
    }
    /// Whether typewriter scrolling is enabled.
    ///
    /// When on (and ``isAutomaticScrollEnabled`` is also on), the vertical center of the line
    /// containing the primary caret stays pinned at ``typewriterAnchorFraction`` of the
    /// viewport while you type or move the caret — the document scrolls beneath it instead of
    /// the caret drifting. Non-empty selections and ``scrollRangeToVisible(_:)`` calls keep
    /// standard minimum-reveal scrolling. Manual scrolling suspends anchoring until the next
    /// key press. Off by default.
    public var isTypewriterScrollingEnabled = false {
        didSet {
            guard isTypewriterScrollingEnabled != oldValue else {
                return
            }
            if !isTypewriterScrollingEnabled {
                isTypewriterScrollingSuspendedByUser = false
            }
            applyEffectiveTextContainerInset()
            hasPendingContentSizeUpdate = true
            setNeedsLayout()
            handleContentSizeUpdateIfNeeded()
            reanchorTypewriterCaretIfNeeded()
        }
    }
    /// The vertical fraction of the viewport (`0` = top, `1` = bottom) where the active line's
    /// center is pinned while ``isTypewriterScrollingEnabled`` is on. Clamped to `0...1`.
    /// Defaults to `0.5` (vertical center). Changing this value also increases bottom
    /// overscroll so the last line can still reach the anchor.
    public var typewriterAnchorFraction: CGFloat = 0.5 {
        didSet {
            let clamped = min(max(typewriterAnchorFraction, 0), 1)
            if clamped != typewriterAnchorFraction {
                typewriterAnchorFraction = clamped
                return
            }
            guard typewriterAnchorFraction != oldValue else {
                return
            }
            applyEffectiveTextContainerInset()
            hasPendingContentSizeUpdate = true
            setNeedsLayout()
            handleContentSizeUpdateIfNeeded()
            reanchorTypewriterCaretIfNeeded()
        }
    }
    /// Enables distraction-free chrome fading. Typing hides editor chrome; mouse movement or an
    /// idle pause restores it. Host-owned chrome is coordinated through ``TextViewDelegate``.
    public var isDistractionFreeModeEnabled: Bool {
        get {
            distractionFreeController.isEnabled
        }
        set {
            distractionFreeController.isEnabled = newValue
        }
    }
    /// Delay after the last key event before hidden chrome returns. Defaults to 1.5 seconds.
    public var distractionFreeIdleDelay: TimeInterval {
        get {
            distractionFreeController.idleDelay
        }
        set {
            distractionFreeController.idleDelay = max(newValue, 0)
        }
    }
    /// Duration of chrome opacity transitions. Defaults to 0.3 seconds.
    public var distractionFreeFadeDuration: TimeInterval {
        get {
            distractionFreeController.fadeDuration
        }
        set {
            distractionFreeController.fadeDuration = max(newValue, 0)
        }
    }
    /// Whether distraction-free chrome is currently visible.
    public var isDistractionFreeChromeVisible: Bool {
        distractionFreeController.isChromeVisible
    }
    /// Manages grouped text emphases such as find matches, bracket pairs, and diagnostics.
    public var emphasisManager: EmphasisManager {
        textInputView.emphasisManager
    }
    /// When set, matching bracket pairs are emphasized as the caret moves.
    public var bracketPairEmphasis: BracketPairEmphasis? {
        get {
            textInputView.bracketPairEmphasis
        }
        set {
            textInputView.bracketPairEmphasis = newValue
        }
    }
    /// Whether the built-in find panel is visible.
    public var isFindPanelVisible: Bool {
        findPanelController.isVisible
    }
    /// Diagnostic ranges rendered as squiggly underlines in the text view.
    public var diagnostics: [TextViewDiagnostic] {
        get {
            textInputView.diagnostics
        }
        set {
            textInputView.diagnostics = newValue
        }
    }
    /// Enable to show highlight the selected lines. The selection is only shown in the gutter when multiple lines are selected.
    public var lineSelectionDisplayType: LineSelectionDisplayType {
        get {
            textInputView.lineSelectionDisplayType
        }
        set {
            textInputView.lineSelectionDisplayType = newValue
        }
    }
    /// The text view renders invisible tabs when enabled. The `tabsSymbol` is used to render tabs.
    public var showTabs: Bool {
        get {
            textInputView.showTabs
        }
        set {
            textInputView.showTabs = newValue
        }
    }
    /// The text view renders invisible spaces when enabled.
    ///
    /// he `spaceSymbol` is used to render spaces.
    public var showSpaces: Bool {
        get {
            textInputView.showSpaces
        }
        set {
            textInputView.showSpaces = newValue
        }
    }
    /// The text view renders invisible spaces when enabled.
    ///
    /// The `nonBreakingSpaceSymbol` is used to render spaces.
    public var showNonBreakingSpaces: Bool {
        get {
            textInputView.showNonBreakingSpaces
        }
        set {
            textInputView.showNonBreakingSpaces = newValue
        }
    }
    /// The text view renders invisible line breaks when enabled.
    ///
    /// The `lineBreakSymbol` is used to render line breaks.
    public var showLineBreaks: Bool {
        get {
            textInputView.showLineBreaks
        }
        set {
            textInputView.showLineBreaks = newValue
        }
    }
    /// The text view renders invisible soft line breaks when enabled.
    ///
    /// The `softLineBreakSymbol` is used to render line breaks. These line breaks are typically represented by the U+2028 unicode character. Penumbra does not provide any key commands for inserting these but supports rendering them.
    public var showSoftLineBreaks: Bool {
        get {
            textInputView.showSoftLineBreaks
        }
        set {
            textInputView.showSoftLineBreaks = newValue
        }
    }
    /// Symbol used to display tabs.
    ///
    /// The value is only used when invisible tab characters is enabled. The default is ▸.
    ///
    /// Common characters for this symbol include ▸, ⇥, ➜, ➞, and ❯.
    public var tabSymbol: String {
        get {
            textInputView.tabSymbol
        }
        set {
            textInputView.tabSymbol = newValue
        }
    }
    /// Symbol used to display spaces.
    ///
    /// The value is only used when showing invisible space characters is enabled. The default is ·.
    ///
    /// Common characters for this symbol include ·, •, and _.
    public var spaceSymbol: String {
        get {
            textInputView.spaceSymbol
        }
        set {
            textInputView.spaceSymbol = newValue
        }
    }
    /// Symbol used to display non-breaking spaces.
    ///
    /// The value is only used when showing invisible space characters is enabled. The default is ·.
    ///
    /// Common characters for this symbol include ·, •, and _.
    public var nonBreakingSpaceSymbol: String {
        get {
            textInputView.nonBreakingSpaceSymbol
        }
        set {
            textInputView.nonBreakingSpaceSymbol = newValue
        }
    }
    /// Symbol used to display line break.
    ///
    /// The value is only used when showing invisible line break characters is enabled. The default is ¬.
    ///
    /// Common characters for this symbol include ¬, ↵, ↲, ⤶, and ¶.
    public var lineBreakSymbol: String {
        get {
            textInputView.lineBreakSymbol
        }
        set {
            textInputView.lineBreakSymbol = newValue
        }
    }
    /// Symbol used to display soft line breaks.
    ///
    /// The value is only used when showing invisible soft line break characters is enabled. The default is ¬.
    ///
    /// Common characters for this symbol include ¬, ↵, ↲, ⤶, and ¶.
    public var softLineBreakSymbol: String {
        get {
            textInputView.softLineBreakSymbol
        }
        set {
            textInputView.softLineBreakSymbol = newValue
        }
    }
    /// The strategy used when indenting text.
    public var indentStrategy: IndentStrategy {
        get {
            textInputView.indentStrategy
        }
        set {
            textInputView.indentStrategy = newValue
        }
    }
    /// The amount of padding before the line numbers inside the gutter.
    public var gutterLeadingPadding: CGFloat {
        get {
            textInputView.gutterLeadingPadding
        }
        set {
            textInputView.gutterLeadingPadding = newValue
        }
    }
    /// The amount of padding after the line numbers inside the gutter.
    public var gutterTrailingPadding: CGFloat {
        get {
            textInputView.gutterTrailingPadding
        }
        set {
            textInputView.gutterTrailingPadding = newValue
        }
    }
    /// The minimum amount of characters to use for width calculation inside the gutter.
    public var gutterMinimumCharacterCount: Int {
        get {
            textInputView.gutterMinimumCharacterCount
        }
        set {
            textInputView.gutterMinimumCharacterCount = newValue
        }
    }
    /// The amount of spacing surrounding the lines.
    public var textContainerInset: UIEdgeInsets {
        get {
            configuredTextContainerInset
        }
        set {
            configuredTextContainerInset = newValue
            applyEffectiveTextContainerInset()
        }
    }
    /// When line wrapping is disabled, users can scroll the text view horizontally to see the entire line.
    ///
    /// Line wrapping is enabled by default.
    public var isLineWrappingEnabled: Bool {
        get {
            textInputView.isLineWrappingEnabled
        }
        set {
            textInputView.isLineWrappingEnabled = newValue
        }
    }
    /// Line break mode for text view. The default value is .byWordWrapping meaning that wrapping occurs on word boundaries.
    public var lineBreakMode: LineBreakMode {
        get {
            textInputView.lineBreakMode
        }
        set {
            textInputView.lineBreakMode = newValue
        }
    }
    /// Width of the gutter.
    public var gutterWidth: CGFloat {
        textInputView.gutterWidth
    }
    /// The line-height is multiplied with the value.
    public var lineHeightMultiplier: CGFloat {
        get {
            textInputView.lineHeightMultiplier
        }
        set {
            textInputView.lineHeightMultiplier = newValue
        }
    }
    /// The number of points by which to adjust kern. The default value is 0 meaning that kerning is disabled.
    public var kern: CGFloat {
        get {
            textInputView.kern
        }
        set {
            textInputView.kern = newValue
        }
    }
    /// The text view shows a page guide when enabled. Use `pageGuideColumn` to specify the location of the page guide.
    public var showPageGuide: Bool {
        get {
            textInputView.showPageGuide
        }
        set {
            textInputView.showPageGuide = newValue
        }
    }
    /// Specifies the location of the page guide. Use `showPageGuide` to specify if the page guide should be shown.
    public var pageGuideColumn: Int {
        get {
            textInputView.pageGuideColumn
        }
        set {
            textInputView.pageGuideColumn = newValue
        }
    }
    /// Automatically scrolls the text view to show the caret when typing or moving the caret.
    ///
    /// When ``isTypewriterScrollingEnabled`` is also on, caret scrolling uses typewriter
    /// anchoring (pin the active line at ``typewriterAnchorFraction``) instead of scrolling
    /// only when the caret leaves the viewport.
    public var isAutomaticScrollEnabled = true {
        didSet {
            guard isAutomaticScrollEnabled != oldValue else {
                return
            }
            reanchorTypewriterCaretIfNeeded()
        }
    }
    /// Amount of overscroll to add in the vertical direction.
    ///
    /// The overscroll is a factor of the scrollable area height and will not take into account any insets. 0 means no overscroll and 1 means an amount equal to the height of the text view. Detaults to 0.
    public var verticalOverscrollFactor: CGFloat = 0 {
        didSet {
            if verticalOverscrollFactor != oldValue {
                hasPendingContentSizeUpdate = true
                handleContentSizeUpdateIfNeeded()
            }
        }
    }
    /// Amount of overscroll to add in the horizontal direction.
    ///
    /// The overscroll is a factor of the scrollable area height and will not take into account any insets or the width of the gutter. 0 means no overscroll and 1 means an amount equal to the width of the text view. Detaults to 0.
    public var horizontalOverscrollFactor: CGFloat = 0 {
        didSet {
            if horizontalOverscrollFactor != oldValue {
                hasPendingContentSizeUpdate = true
                handleContentSizeUpdateIfNeeded()
            }
        }
    }
    /// Ranges in the text to be highlighted. The color defined by the background will be drawen behind the text.
    public var highlightedRanges: [HighlightedRange] {
        get {
            textInputView.highlightedRanges
        }
        set {
            textInputView.highlightedRanges = newValue
            highlightNavigationController.highlightedRanges = newValue
        }
    }
    /// Wheter the text view should loop when navigating through highlighted ranges using `selectPreviousHighlightedRange` or `selectNextHighlightedRange` on the text view.
    public var highlightedRangeLoopingMode: HighlightedRangeLoopingMode {
        get {
            if highlightNavigationController.loopRanges {
                return .enabled
            } else {
                return .disabled
            }
        }
        set {
            switch newValue {
            case .enabled:
                highlightNavigationController.loopRanges = true
            case .disabled:
                highlightNavigationController.loopRanges = false
            }
        }
    }
    /// Line endings to use when inserting a line break.
    ///
    /// The value only affects new line breaks inserted in the text view and changing this value does not change the line endings of the text in the text view. Defaults to Unix (LF).
    ///
    /// The TextView will only update the line endings when text is modified through an external event, such as when the user typing on the keyboard, when the user is replacing selected text, and when pasting text into the text view. In all other cases, you should make sure that the text provided to the text view uses the desired line endings. This includes when calling ``TextView/setState(_:addUndoAction:)`` and ``TextView/replaceText(in:)``.
    public var lineEndings: LineEnding {
        get {
            textInputView.lineEndings
        }
        set {
            textInputView.lineEndings = newValue
        }
    }
    /// When enabled the text view will present a menu with actions actions such as Copy and Replace after navigating to a highlighted range.
    public var showMenuAfterNavigatingToHighlightedRange = true
    /// A boolean value that enables a text view’s built-in find interaction.
    ///
    /// After enabling the find interaction, use [`presentFindNavigator(showingReplace:)`](https://developer.apple.com/documentation/uikit/uifindinteraction/3975832-presentfindnavigator) on <doc:findInteraction> to present the find navigator.
    public var isFindInteractionEnabled: Bool {
        get {
            textSearchingHelper.isFindInteractionEnabled
        }
        set {
            textSearchingHelper.isFindInteractionEnabled = newValue
        }
    }
    /// The text view’s built-in find interaction.
    ///
    /// Set <doc:isFindInteractionEnabled> to true to enable the text view's built-in find interaction. This method returns nil when the interaction isn't enabled.
    ///
    /// Call [`presentFindNavigator(showingReplace:)`](https://developer.apple.com/documentation/uikit/uifindinteraction/3975832-presentfindnavigator) on the UIFindInteraction object to invoke the find interaction and display the find panel.
    public var findInteraction: UIFindInteraction? {
        textSearchingHelper.findInteraction
    }

    /// Whether a miniature overview of the document is shown along the trailing edge of the
    /// text view. Off by default.
    public var showMinimap = false {
        didSet {
            if showMinimap != oldValue {
                if showMinimap {
                    minimapView.isHidden = false
                } else {
                    minimapView.collapseOverlay()
                }
                setNeedsLayout()
            }
        }
    }
    /// Whether floating overlay scrollers are shown when the content overflows. On by default.
    ///
    /// The vertical scroller is suppressed while ``showMinimap`` is true, since the minimap's
    /// viewport indicator already fills that role; the horizontal scroller is unaffected by the
    /// minimap. Both fade out when idle, or stay visible if the system's "Show scroll bars" setting
    /// is "Always".
    public var showsScrollers = true {
        didSet {
            if showsScrollers != oldValue {
                setNeedsLayout()
            }
        }
    }
    /// Width, in points, of the minimap shown when ``showMinimap`` is true.
    public var minimapWidth: CGFloat = 100 {
        didSet {
            if minimapWidth != oldValue && showMinimap {
                setNeedsLayout()
            }
        }
    }
    /// Host-controlled Metal rendering preference. Defaults to `true` (production) or `false` under
    /// XCTest. Ignored when no Metal device exists. A `false` value always wins over
    /// `UserDefaults` `PenumbraMetalRendering` `true` (per-view disable).
    public var isMetalRenderingEnabled: Bool {
        get {
            textInputView.isMetalRenderingEnabled
        }
        set {
            textInputView.isMetalRenderingEnabled = newValue
        }
    }
    /// `true` when this instance is currently presenting the Metal canvas.
    public var isMetalRenderingActive: Bool {
        textInputView.isMetalRenderingActive
    }
    /// Called when Metal permanently falls back to Core Graphics after a device or pipeline failure.
    public var onMetalRenderingFailure: ((String) -> Void)? {
        get { textInputView.onMetalRenderingFailure }
        set { textInputView.onMetalRenderingFailure = newValue }
    }
    /// Resident coverage (R8) glyph-atlas bytes for the process-wide atlas. Debug/PerfHarness only.
    public var metalGlyphAtlasBytes: Int { textInputView.metalDebugStats?.coverageAtlasBytes ?? 0 }
    /// Resident color (BGRA) glyph-atlas bytes for the process-wide atlas. Debug/PerfHarness only.
    public var metalColorAtlasBytes: Int { textInputView.metalDebugStats?.colorAtlasBytes ?? 0 }
    /// Number of line fragments this instance is currently painting via Metal. Debug/PerfHarness only.
    public var metalFragmentCount: Int { textInputView.metalDebugStats?.fragmentCount ?? 0 }
    /// Glyph + solid instance count from the last Metal encode. Debug/PerfHarness only.
    public var metalInstanceCount: Int {
        (textInputView.metalDebugStats?.glyphInstanceCount ?? 0) + (textInputView.metalDebugStats?.solidInstanceCount ?? 0)
    }
    /// Windowed p95 of `MetalRenderer.encode`, in nanoseconds. Debug/PerfHarness only.
    public var metalDrawNanosP95: Double { textInputView.metalDebugStats?.drawNanosP95 ?? 0 }
    /// One non-blocking snapshot for benchmark/HUD callers that need several Metal counters.
    public var metalPerformanceStats: MetalPerformanceStats? {
        guard let stats = textInputView.metalDebugStats else {
            return nil
        }
        return MetalPerformanceStats(
            fragmentCount: stats.fragmentCount,
            glyphInstanceCount: stats.glyphInstanceCount,
            solidInstanceCount: stats.solidInstanceCount,
            coverageAtlasBytes: stats.coverageAtlasBytes,
            colorAtlasBytes: stats.colorAtlasBytes,
            drawNanosP95: stats.drawNanosP95,
            rasterCapSkipCount: stats.rasterCapSkipCount,
            instanceRebuildNanos: stats.instanceRebuildNanos,
            decorationBuildCount: stats.decorationBuildCount,
            glyphBufferRebuildCount: stats.glyphBufferRebuildCount,
            solidBufferRebuildCount: stats.solidBufferRebuildCount
        )
    }
    /// Glyph instance colors Metal currently holds for the line at `location` (or every fragment
    /// when `location` is `nil`), empty when Metal is inactive. Debug/test only — lets a test
    /// assert directly that a line's on-screen colors are not `theme.textColor` instead of
    /// inferring it from painted-pixel counts.
    public func metalDebugGlyphColors(atLocation location: Int? = nil) -> [SIMD4<Float>] {
        textInputView.metalDebugGlyphColors(atLocation: location)
    }
    /// Glyph instance origins Metal currently holds for the line at `location`. Debug/test only.
    public func metalDebugGlyphOrigins(atLocation location: Int? = nil) -> [SIMD2<Float>] {
        textInputView.metalDebugGlyphOrigins(atLocation: location)
    }
    /// When `true`, the Metal canvas is created with `framebufferOnly = false` so
    /// the present command buffer can read back the submitted drawable. Off in the shipping path;
    /// set it (before creating a `TextView`) only from PerfHarness / snapshot tests.
    public static var allowsMetalDrawableCapture: Bool {
        get { MetalContext.shared.allowsDrawableCapture }
        set { MetalContext.shared.allowsDrawableCapture = newValue }
    }
    /// Offscreen render of the opaque Metal glyph canvas (chrome + glyphs + decorations) at
    /// the backing scale, or `nil` when Metal is not active. Snapshot tests / PerfHarness only.
    public func captureMetalGlyphSnapshot() -> NSBitmapImageRep? {
        textInputView.captureMetalSnapshot()
    }
    /// Presented Metal canvas via drawable readback. Requires ``allowsMetalDrawableCapture`` to
    /// have been set before this view was created. Snapshot tests / PerfHarness only.
    public func captureMetalPresentedLayer() -> NSBitmapImageRep? {
        textInputView.captureMetalPresentedLayer()
    }
    /// Swift `GlyphInstance` stride used as the vertex-buffer stride. Snapshot tests / PerfHarness.
    public var metalGlyphInstanceStride: Int { textInputView.metalDebugStats?.glyphInstanceStride ?? 0 }
    /// Swift `GlyphInstance` size (may be less than stride due to alignment padding).
    public var metalGlyphInstanceSize: Int { textInputView.metalDebugStats?.glyphInstanceSize ?? 0 }
    /// Explicitly performs the expensive GPU readback used by atlas diagnostics.
    /// Returns non-zero texels, total texels, and coverage-page count.
    public func metalAtlasCensus() -> (nonzero: Int, total: Int, pages: Int)? {
        textInputView.metalAtlasCensus
    }
    /// Coordinates pluggable syntax-highlight providers (tree-sitter overlays, semantic tokens, etc.).
    public private(set) var highlightProviderCoordinator: HighlightProviderCoordinator?

    /// Attach highlight providers and begin coordinating invalidation and queries.
    public func configureHighlightProviders(_ providers: [HighlightProviding]) {
        let coordinator = HighlightProviderCoordinator()
        coordinator.attach(to: self, providers: providers)
        coordinator.onHighlightsChanged = { [weak self] in
            self?.textInputView.setNeedsDisplay()
        }
        highlightProviderCoordinator = coordinator
    }

    /// Tree-sitter highlight captures intersecting `range`, or `[]` when there is no tree.
    func syntaxHighlightCaptures(in range: NSRange) -> [TreeSitterCapture] {
        textInputView.minimapCaptures(inByteRange: ByteRange(utf16Range: range))
    }

    private let textInputView: TextInputView
    private let writeLock = DocumentWriteLock()
    private let minimapView = MinimapView(frame: .zero)
    #if DEBUG
    /// Test hook — the minimap overlay, so tests can render and probe it directly.
    var minimapViewForTesting: MinimapView { minimapView }
    /// Test hook — the overlay scrollers, so tests can probe and drive them directly.
    var scrollerOverlayForTesting: ScrollerOverlayController { scrollerOverlay }
    #endif
    private let scrollerOverlay = ScrollerOverlayController()
    private let tapGestureRecognizer = QuickTapGestureRecognizer()
    private var _inputAccessoryView: UIView?
    private var delegateAllowsEditingToBegin: Bool {
        guard isEditable else {
            return false
        }
        if let editorDelegate = editorDelegate {
            return editorDelegate.textViewShouldBeginEditing(self)
        } else {
            return true
        }
    }
    private var shouldEndEditing: Bool {
        if let editorDelegate = editorDelegate {
            return editorDelegate.textViewShouldEndEditing(self)
        } else {
            return true
        }
    }
    private var hasPendingContentSizeUpdate = false
    private var deferredInputLayoutFlushScheduled = false
    private var lastLaidOutSize: CGSize = .zero
    private var configuredTextContainerInset: UIEdgeInsets = .zero
    private var isInputAccessoryViewEnabled = false
    private let keyboardObserver = KeyboardObserver()
    private let highlightNavigationController = HighlightNavigationController()
    private let distractionFreeController = DistractionFreeController()
    private var distractionFreeTrackingArea: NSTrackingArea?
    private var textSearchingHelper = UITextSearchingHelper()
    private lazy var findPanelController: FindPanelController = {
        let controller = FindPanelController(target: self)
        controller.emphasisManager = textInputView.emphasisManager
        addFixedOverlaySubview(controller.panelView)
        return controller
    }()
    private var findPanelTopInset: CGFloat = 0
    // Store a reference to instances of the private type UITextRangeAdjustmentGestureRecognizer in order to track adjustments
    // to the selected text range and scroll the text view when the handles approach the bottom.
    // The approach is based on the one described in Steve Shephard's blog post "Adventures with UITextInteraction".
    // https://steveshepard.com/blog/adventures-with-uitextinteraction/
    private var textRangeAdjustmentGestureRecognizers: Set<UIGestureRecognizer> = []
    private var previousSelectedRangeDuringGestureHandling: NSRange?
    private var preferredContentSize: CGSize {
        let horizontalOverscrollLength = max(frame.width * horizontalOverscrollFactor, 0)
        var verticalOverscrollLength = max(frame.height * verticalOverscrollFactor, 0)
        if isTypewriterScrollingEnabled {
            let viewportHeight = max(frame.height - adjustedContentInset.top - adjustedContentInset.bottom, 0)
            let typewriterOverscrollLength = TypewriterScrollingPolicy.requiredBottomOverscroll(
                viewportHeight: viewportHeight,
                anchorFraction: typewriterAnchorFraction
            )
            verticalOverscrollLength = max(verticalOverscrollLength, typewriterOverscrollLength)
        }
        let baseContentSize = textInputView.contentSize
        let width = isLineWrappingEnabled ? baseContentSize.width : baseContentSize.width + horizontalOverscrollLength
        let height = baseContentSize.height + verticalOverscrollLength
        return CGSize(width: width, height: height)
    }
    private var scrollPocketView: UIView? {
        if let _scrollPocketView = _scrollPocketView {
            return _scrollPocketView
        } else {
            let stringType = String("IU_".reversed()) + "Scroll" + String("tekcoP".reversed())
            let scrollPocketView = subviews.first { view in
                String(describing: type(of: view)) == stringType
            } as? UIView
            _scrollPocketView = scrollPocketView
            return scrollPocketView
        }
    }
    private var _scrollPocketView: UIView?
    private var isTypewriterScrollingSuspendedByUser = false
    private var lastTypewriterCaretMoveTime: TimeInterval = 0


    /// Create a new text view.
    /// - Parameter frame: The frame rectangle of the text view.
    override public init(frame: CGRect) {
        textInputView = TextInputView(theme: DefaultTheme())
        super.init(frame: frame)
        // Follow system text background so dark mode doesn't leave a white
        // canvas beside a dark gutter (DefaultTheme reads appearance colors).
        backgroundColor = .textBackgroundColor
        textInputView.delegate = self
        textInputView.gutterParentView = self
        textInputView.languageConfiguration = resolvedLanguageConfiguration
        addSubview(textInputView)
        minimapView.lineDataSource = textInputView
        minimapView.scrollView = self
        minimapView.onUserScroll = { [weak self] in
            self?.suspendTypewriterScrollingForUserInteraction()
        }
        minimapView.isHidden = true
        minimapView.applyTheme()
        minimapView.collapseOverlay()
        addFixedOverlaySubview(minimapView)
        scrollerOverlay.install(in: self, themeSource: textInputView) { [weak self] in
            self?.suspendTypewriterScrollingForUserInteraction()
        }
        // Keep the minimap's indicator and the scrollers in sync with programmatic and animated
        // scrolls, which don't necessarily trigger a layout pass (see `scrollWheel`'s note).
        onDidScroll = { [weak self] in
            guard let self else { return }
            if self.showMinimap {
                self.minimapView.setNeedsDisplayForContentChange()
            }
            self.scrollerOverlay.handleScroll()
        }
        _ = findPanelController.panelView
        tapGestureRecognizer.delegate = self
        tapGestureRecognizer.addTarget(self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tapGestureRecognizer)
        installNonEditableInteraction()
        keyboardObserver.delegate = self
        highlightNavigationController.delegate = self
        textSearchingHelper.textView = self
        distractionFreeController.onVisibilityChange = { [weak self] isVisible, duration in
            self?.applyDistractionFreeChromeVisibility(isVisible, duration: duration)
        }
    }

    /// The initializer has not been implemented.
    /// - Parameter coder: Not used.
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Lays out subviews.
    override open func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === tapGestureRecognizer {
            return !isEditing && !isDragging && !isDecelerating && delegateAllowsEditingToBegin
        } else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
    }

    override open func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        textInputView.handleBackingPropertiesChange()
    }

    /// Adds the space reserved for the top-anchored find bar (``findPanelTopInset``) on top of
    /// whatever inset the host configured, so scrolling-to-top rests below the bar instead of
    /// under it. Every consumer of `adjustedContentInset` — `scrollViewport(at:)`,
    /// `minimumContentOffset`/`maximumContentOffset`, typewriter scrolling — picks this up for
    /// free.
    override open var adjustedContentInset: UIEdgeInsets {
        var inset = contentInset
        inset.top += findPanelTopInset
        return inset
    }

    override open func layoutSubviews() {
        super.layoutSubviews()
        // SwiftUI often sizes the host after the first setState. Without
        // re-arming contentSize, the document stays stuck at the zero-frame
        // measurement and scrolling dies.
        var shouldReanchorAfterLayout = false
        if frame.size != lastLaidOutSize {
            shouldReanchorAfterLayout = frame.size != .zero
            lastLaidOutSize = frame.size
            applyEffectiveTextContainerInset()
            hasPendingContentSizeUpdate = true
        }
        handleContentSizeUpdateIfNeeded()
        // Reserve room on the trailing edge for the minimap so wrapped lines stop before
        // reaching it, matching how the gutter's width is already accounted for by
        // constrainingLineWidth on the leading edge.
        let reservedMinimapWidth = showMinimap ? minimapWidth : 0
        // Always-visible (legacy) system scrollers take a permanent strip; overlay scrollers
        // float over the text and reserve nothing.
        let reservedScrollerWidth = scrollerOverlay.reservedTrailingWidth(for: self)
        textInputView.scrollViewWidth = frame.width - reservedMinimapWidth - reservedScrollerWidth
        textInputView.frame = CGRect(x: 0, y: 0, width: max(contentSize.width, frame.width), height: max(contentSize.height, frame.height))
        textInputView.viewport = CGRect(origin: contentOffset, size: frame.size)
        // UIView.layout does not walk children; explicitly layout the input view
        // so viewport-driven line fragments exist for the current offset.
        textInputView.layoutIfNeeded()
        textInputView.ensureViewportSyntaxParse()
        if let canvas = subviews.compactMap({ $0 as? MetalTextCanvasView }).first,
           let clipView = subviews.first(where: { $0 is NSClipView }) {
            // Pin the canvas just above the clip view — never relative to "the first non-canvas
            // sibling", which is often the caret overlay and would hide the insertion point.
            insertFixedOverlaySubview(canvas, positioned: .above, relativeTo: clipView)
        }
        textInputView.placeSelectionChromeAboveMetalCanvas()
        bringSubviewToFront(textInputView.gutterContainerView)
        if let scrollPocketView {
            bringSubviewToFront(scrollPocketView)
        }
        if showMinimap {
            minimapView.isHidden = false
            minimapView.frame = CGRect(x: bounds.maxX - minimapWidth, y: 0, width: minimapWidth, height: bounds.height)
            bringSubviewToFront(minimapView)
            minimapView.setNeedsDisplayForContentChange()
        } else {
            // Collapse the overlay so the viewport-indicator's CALayer border can't sit at the
            // trailing edge. `isHidden` alone does not always clip a layer-backed child's border.
            minimapView.collapseOverlay()
        }
        scrollerOverlay.layout(in: self)
        let panelHeight = findPanelController.isVisible ? findPanelController.panelHeight : 0
        findPanelController.panelView.frame = CGRect(x: 0,
                                                     y: 0,
                                                     width: bounds.width - reservedMinimapWidth,
                                                     height: panelHeight)
        if shouldReanchorAfterLayout {
            reanchorTypewriterCaretIfNeeded()
        }
    }

    /// Forwards to the base scroll handling, then keeps the minimap's viewport indicator in sync.
    /// Scrolling changes `contentOffset` without necessarily triggering a fresh `layoutSubviews()`
    /// pass on every tick, so the minimap can't rely on that alone to stay positioned correctly.
    override open func scrollWheel(with event: NSEvent) {
        if isTypewriterScrollingEnabled {
            suspendTypewriterScrollingForUserInteraction()
            cancelAnimatedScrolling()
        }
        super.scrollWheel(with: event)
        if showMinimap {
            minimapView.setNeedsDisplayForContentChange()
        }
        // Also covers a wheel event that hit the end of the document and didn't move it.
        scrollerOverlay.flash()
    }

    override open func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let distractionFreeTrackingArea {
            removeTrackingArea(distractionFreeTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        distractionFreeTrackingArea = trackingArea
    }

    override open func mouseMoved(with event: NSEvent) {
        distractionFreeController.mouseDidMove()
        scrollerOverlay.mouseMoved(to: convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    /// Called when the safe area of the view changes.
    override open func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        textInputView.scrollViewSafeAreaInsets = safeAreaInsets
        hasPendingContentSizeUpdate = true
        setNeedsLayout()
    }

    /// Asks UIKit to make this object the first responder in its window.
    @discardableResult
    override open func becomeFirstResponder() -> Bool {
        if !isEditing && delegateAllowsEditingToBegin {
            _ = textInputView.resignFirstResponder()
            _ = textInputView.becomeFirstResponder()
            return true
        } else {
            return false
        }
    }

    /// Notifies this object that it has been asked to relinquish its status as first responder in its window.
    @discardableResult
    override open func resignFirstResponder() -> Bool {
        if isEditing && shouldEndEditing {
            return textInputView.resignFirstResponder()
        } else {
            return false
        }
    }

    /// Installs the underlying text input as the window's first responder.
    ///
    /// `becomeFirstResponder()` alone does not install first-responder status in AppKit —
    /// only `NSWindow.makeFirstResponder(_:)` does, and this is the only way to reach the
    /// private `textInputView` that arrow-key navigation and selection live on. Unlike
    /// `becomeFirstResponder()`, this works for a non-editable, selectable text view too,
    /// so read-only editors can be given keyboard focus for navigation/selection/copy.
    @discardableResult
    public func focusTextInput() -> Bool {
        guard let window, isSelectable else {
            return false
        }
        return window.makeFirstResponder(textInputView)
    }

    /// Calls ``focusTextInput()``, retrying once on the next runloop turn if it fails because the
    /// view isn't attached to a window yet — e.g. when called while a SwiftUI-hosted `TextView` is
    /// still being created. Bounded to a single retry so a view that's never added to a window
    /// gives up silently rather than looping.
    public func focusTextInputWhenReady(retriesRemaining: Int = 1) {
        guard !focusTextInput() else {
            return
        }
        guard retriesRemaining > 0 else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.focusTextInputWhenReady(retriesRemaining: retriesRemaining - 1)
        }
    }

    /// Updates the custom input and accessory views when the object is the first responder.
    override open func reloadInputViews() {
        textInputView.reloadInputViews()
    }

    /// Sets the current _state_ of the editor. The state contains the text to be displayed by the editor and
    /// various additional information about the text that the editor needs to show the text.
    ///
    /// It is safe to create an instance of <code>TextViewState</code> in the background, and as such it can be
    /// created before presenting the editor to the user, e.g. when opening the document from an instance of
    /// <code>UIDocumentBrowserViewController</code>.
    ///
    /// This is the preferred way to initially set the text, language and theme on the <code>TextView</code>.
    /// - Parameter state: The new state to be used by the editor.
    /// - Parameter addUndoAction: Whether the state change can be undone. Defaults to false.
    public func setState(_ state: TextViewState, addUndoAction: Bool = false) {
        textInputView.setState(state, addUndoAction: addUndoAction)
        hasPendingContentSizeUpdate = true
        setNeedsLayout()
    }

    /// Snapshots the live buffer, line index, and language mode without copying document text.
    ///
    /// The returned state aliases the objects currently installed on this view. After a subsequent
    /// ``setState(_:addUndoAction:)``, those objects are no longer used here and the snapshot is
    /// their unique owner — safe to re-apply to restore this document (tab switch, split-pane
    /// handoff) without going through empty ``WorkbenchDocument/text`` on a file-backed buffer.
    public func makeCapturedState() -> TextViewState {
        textInputView.makeCapturedState()
    }

    /// Whether the current language mode has finished its initial syntax parse.
    ///
    /// Always `true` for plain text and for ``SyntaxParsePolicy/eager`` state after `setState`.
    /// Becomes `true` for ``SyntaxParsePolicy/deferred`` and ``SyntaxParsePolicy/viewport`` state after
    /// ``TextViewDelegate/textViewDidFinishSyntaxParse(_:)``.
    public var isSyntaxTreeReady: Bool {
        textInputView.isSyntaxTreeReady
    }

    /// Cancels an in-flight deferred syntax parse started by ``setState(_:addUndoAction:)``
    /// or ``setLanguageMode(_:completion:)``.
    ///
    /// ``TextViewDelegate/textViewDidFinishSyntaxParse(_:)`` is not called for the cancelled parse.
    public func cancelSyntaxParse() {
        textInputView.cancelSyntaxParse()
    }

    /// Returns the row and column at the specified location in the text.
    /// Common usages of this includes showing the line and column that the caret is currently located at.
    /// - Parameter location: The location is relative to the first index in the string.
    /// - Returns: The text location if the input location could be found in the string, otherwise nil.
    public func textLocation(at location: Int) -> TextLocation? {
        if let linePosition = textInputView.linePosition(at: location) {
            return TextLocation(linePosition)
        } else {
            return nil
        }
    }

    /// UTF-16 offset closest to `point` in the text view's coordinate space.
    public func characterIndex(at point: CGPoint) -> Int? {
        textInputView.characterIndex(at: textInputView.convert(point, from: self))
    }

    /// Returns the character location at the specified row and column.
    /// - Parameter textLocation: The row and column in the text.
    /// - Returns: The location if the input row and column could be found in the text, otherwise nil.
    public func location(at textLocation: TextLocation) -> Int? {
        let lineIndex = textLocation.lineNumber
        guard lineIndex >= 0 && lineIndex < textInputView.lineManager.lineCount else {
            return nil
        }
        let line = textInputView.lineManager.line(atRow: lineIndex)
        guard textLocation.column >= 0 && textLocation.column <= line.data.totalLength else {
            return nil
        }
        return line.location + textLocation.column
    }

    /// Sets the language mode on a background thread.
    ///
    /// - Parameters:
    ///   - languageMode: The new language mode to be used by the editor.
    ///   - completion: Called when the content have been parsed or when parsing fails.
    public func setLanguageMode(_ languageMode: LanguageMode, completion: ((Bool) -> Void)? = nil) {
        textInputView.setLanguageMode(languageMode, completion: completion)
    }

    /// Inserts text at the location of the caret or, if no selection or caret is present, at the end of the text.
    /// - Parameter text: A string to insert.
    open func insertText(_ text: String) {
        textInputView.inputDelegate?.selectionWillChange(textInputView)
        textInputView.insertText(text)
        textInputView.inputDelegate?.selectionDidChange(textInputView)
    }

    /// Replaces the text that is in the specified range.
    /// - Parameters:
    ///   - range: A range of text in the document.
    ///   - text: A string to replace the text in range.
    open func replace(_ range: UITextRange, withText text: String) {
        textInputView.inputDelegate?.selectionWillChange(textInputView)
        textInputView.replace(range, withText: text)
        textInputView.inputDelegate?.selectionDidChange(textInputView)
    }

    /// Replaces the text that is in the specified range.
    /// - Parameters:
    ///   - range: A range of text in the document.
    ///   - text: A string to replace the text in range.
    public func replace(_ range: NSRange, withText text: String) {
        textInputView.inputDelegate?.selectionWillChange(textInputView)
        let indexedRange = IndexedRange(range)
        textInputView.replace(indexedRange, withText: text)
        textInputView.inputDelegate?.selectionDidChange(textInputView)
    }

    /// Replaces the text in the specified matches.
    /// - Parameters:
    ///   - batchReplaceSet: Set of ranges to replace with a text.
    public func replaceText(in batchReplaceSet: BatchReplaceSet) {
        textInputView.replaceText(in: batchReplaceSet)
    }

    /// Deletes a character from the displayed text.
    public func deleteBackward() {
        textInputView.deleteBackward()
    }

    /// Returns the text in the specified range.
    /// - Parameter range: A range of text in the document.
    /// - Returns: The substring that falls within the specified range.
    public func text(in range: NSRange) -> String? {
        textInputView.text(in: range)
    }

    /// Returns the syntax node at the specified location in the document.
    ///
    /// This can be used with character pairs to determine if a pair should be inserted or not.
    /// For example, a character pair consisting of two quotes (") to surround a string, should probably not be
    /// inserted when the quote is typed while the caret is already inside a string.
    ///
    /// This requires a language to be set on the editor.
    /// - Parameter location: A location in the document.
    /// - Returns: The syntax node at the location.
    public func syntaxNode(at location: Int) -> SyntaxNode? {
        textInputView.syntaxNode(at: location)
    }

    /// Performs a keymap action programmatically — the same entry point key bindings use.
    /// Core actions run directly; anything else is offered to ``editorActionHandler``.
    /// - Returns: `true` if the action was handled.
    @discardableResult
    public func perform(_ action: EditorActionID) -> Bool {
        if textInputView.performKeymapAction(action, isEditable: isEditable) {
            return true
        }
        if editorActionHandler?(action) == true {
            return true
        }
        switch action {
        case .navigateBack:
            return navigateBack()
        case .navigateForward:
            return navigateForward()
        case .reformatCode:
            return textInputView.performFallbackAction(action, isEditable: isEditable)
        case .toggleMethodSeparators:
            showMethodSeparators.toggle()
            return true
        case .toggleOccurrenceHighlighting:
            highlightsOccurrencesOfSelection.toggle()
            return true
        default:
            return false
        }
    }

    /// A plain language identifier (`"swift"`, `"python"`, …) for features that vary by
    /// language: ``applicableSurroundTemplates()`` and ``languageConfiguration``. Not derived
    /// automatically — set it alongside ``setLanguageMode(_:completion:)`` if you use those
    /// features. See ``LanguageIdentifier``.
    public var languageIdentifier: String? {
        didSet {
            if languageIdentifier != oldValue {
                textInputView.languageConfiguration = resolvedLanguageConfiguration
            }
        }
    }

    /// Templates offered by ``EditorActionID/surroundWith``. Defaults to
    /// ``SurroundTemplate/builtIns``.
    public var surroundTemplates: [SurroundTemplate] = SurroundTemplate.builtIns

    /// ``surroundTemplates`` filtered to those applicable to ``languageIdentifier``.
    public func applicableSurroundTemplates() -> [SurroundTemplate] {
        surroundTemplates.filter { $0.applies(to: languageIdentifier) }
    }

    /// Per-language behaviour for method separators, breadcrumbs, and occurrence highlighting,
    /// keyed on ``languageIdentifier``. Defaults to ``LanguageConfigurationRegistry/builtIns``.
    public var languageConfigurations: LanguageConfigurationRegistry = .builtIns {
        didSet {
            textInputView.languageConfiguration = resolvedLanguageConfiguration
        }
    }

    /// Set to force a specific configuration regardless of ``languageIdentifier``. `nil` (default)
    /// resolves from ``languageConfigurations``.
    public var languageConfigurationOverride: LanguageConfiguration? {
        didSet {
            textInputView.languageConfiguration = resolvedLanguageConfiguration
        }
    }

    /// The configuration currently in effect: ``languageConfigurationOverride`` if set, otherwise
    /// ``languageConfigurations`` resolved for ``languageIdentifier`` (falling back to
    /// ``LanguageConfiguration/generic``).
    public var languageConfiguration: LanguageConfiguration {
        resolvedLanguageConfiguration
    }

    private var resolvedLanguageConfiguration: LanguageConfiguration {
        languageConfigurationOverride ?? languageConfigurations.configuration(for: languageIdentifier)
    }

    /// Draw a hairline separator above each method/function (and type) declaration, IntelliJ-style.
    /// Uses ``languageConfiguration`` to decide what a declaration is. Off by default.
    public var showMethodSeparators: Bool {
        get {
            textInputView.showMethodSeparators
        }
        set {
            textInputView.showMethodSeparators = newValue
        }
    }

    /// Highlight every other occurrence of the current selection (or the word under the caret when
    /// the selection is empty). Off by default.
    public var highlightsOccurrencesOfSelection: Bool {
        get {
            textInputView.highlightsOccurrencesOfSelection
        }
        set {
            textInputView.highlightsOccurrencesOfSelection = newValue
        }
    }

    /// Wraps the current selection using `template`, expanding its snippet body with the
    /// selection substituted for `$TM_SELECTED_TEXT` and re-indenting to the current line.
    public func surroundSelection(with template: SurroundTemplate) {
        textInputView.surroundSelection(with: template)
    }

    /// Inserts an expanded snippet and starts a tab-stop session when the expansion has numbered stops.
    public func insertSnippet(_ expansion: SnippetExpansion, replacing range: NSRange, extraIndentPerNewline: Int = 0) {
        textInputView.insertSnippet(expansion, replacing: range, extraIndentPerNewline: extraIndentPerNewline)
    }

    /// True while Tab / Shift-Tab cycle snippet placeholders.
    public var hasActiveSnippetSession: Bool {
        textInputView.hasActiveSnippetSession
    }

    @discardableResult
    public func advanceSnippetSession() -> Bool {
        textInputView.advanceSnippetSession()
    }

    @discardableResult
    public func retreatSnippetSession() -> Bool {
        textInputView.retreatSnippetSession()
    }

    public func cancelSnippetSession() {
        textInputView.cancelSnippetSession()
    }

    /// Re-indents the lines touched by the current selection using the active language mode's
    /// indentation rules. This is the non-LSP fallback for ``EditorActionID/reformatCode``;
    /// prefer an LSP formatter when one is available.
    public func reindentSelectedLines() {
        textInputView.reindentSelectedLines()
    }

    // MARK: - Navigation history

    /// Back/forward stack of caret positions for ``EditorActionID/navigateBack`` /
    /// ``navigateForward`` (⌘[ / ⌘]). Fed automatically by significant cursor moves and by
    /// ``recordNavigationCheckpoint()`` before programmatic jumps. Assign a shared instance
    /// across several text views (e.g. a workbench's panes) to get cross-document history.
    public var navigationHistory = NavigationHistory()
    /// Identifier the host assigns to the current document, copied onto every
    /// ``NavigationEntry`` so a multi-document host can route a cross-file back/forward jump.
    public var documentIdentifier: UUID?
    /// URL of the current document, if any — also copied onto ``NavigationEntry`` values.
    public var documentURL: URL?
    /// Invoked when back/forward lands on an entry belonging to a *different* document. Return
    /// `true` if the host performed the navigation (opened the file and focused the location);
    /// otherwise `TextView` falls back to moving within the current document.
    public var onNavigateToHistoryEntry: ((NavigationEntry) -> Bool)?
    private var isApplyingHistoryNavigation = false

    /// The current caret position as a ``NavigationEntry``.
    public func currentNavigationEntry() -> NavigationEntry {
        let location = selectedRange.location
        let position = textLocation(at: location) ?? TextLocation(lineNumber: 0, column: 0)
        return NavigationEntry(documentID: documentIdentifier, url: documentURL, location: position)
    }

    /// Records the current caret position as a history stop — call right before any
    /// programmatic jump the user should be able to step back from.
    public func recordNavigationCheckpoint() {
        guard !isApplyingHistoryNavigation else { return }
        navigationHistory.recordCheckpoint(currentNavigationEntry())
    }

    @discardableResult
    public func navigateBack() -> Bool {
        guard let target = navigationHistory.goBack(from: currentNavigationEntry()) else { return false }
        return applyHistoryEntry(target)
    }

    @discardableResult
    public func navigateForward() -> Bool {
        guard let target = navigationHistory.goForward(from: currentNavigationEntry()) else { return false }
        return applyHistoryEntry(target)
    }

    private func applyHistoryEntry(_ entry: NavigationEntry) -> Bool {
        if entry.documentID != documentIdentifier || entry.url != documentURL,
           onNavigateToHistoryEntry?(entry) == true {
            return true
        }
        guard let location = location(at: entry.location) else { return false }
        isApplyingHistoryNavigation = true
        defer { isApplyingHistoryNavigation = false }
        textInputView.selection = NSRange(location: location, length: 0)
        scrollRangeToVisible(NSRange(location: location, length: 0))
        return true
    }

    /// Checks if the specified locations is within the indentation of the line.
    ///
    /// - Parameter location: A location in the document.
    /// - Returns: True if the location is within the indentation of the line, otherwise false.
    public func isIndentation(at location: Int) -> Bool {
        textInputView.isIndentation(at: location)
    }

    /// Decreases the indentation level of the selected lines.
    public func shiftLeft() {
        textInputView.shiftLeft()
    }

    /// Increases the indentation level of the selected lines.
    public func shiftRight() {
        textInputView.shiftRight()
    }

    /// Moves the selected lines up by one line.
    ///
    /// Calling this function has no effect when the selected lines include the first line in the text view.
    public func moveSelectedLinesUp() {
        textInputView.moveSelectedLinesUp()
    }

    /// Moves the selected lines down by one line.
    ///
    /// Calling this function has no effect when the selected lines include the last line in the text view.
    public func moveSelectedLinesDown() {
        textInputView.moveSelectedLinesDown()
    }

    /// Expands the selection to the full contents of every line it touches, including each line's
    /// trailing line break (⌘L). Runs per caret when multiple selections are active. Calling it
    /// again with the resulting selection has no further effect.
    public func selectLines() {
        textInputView.selectLines()
    }

    /// Inserts a copy of every line touched by the current selection immediately below it, in a
    /// single undo step, leaving the caret set on the inserted copy (⌘D).
    public func duplicateSelectedLines() {
        textInputView.duplicateSelectedLines()
    }

    /// Deletes every line touched by the current selection, in a single undo step (⌘⌫). Deleting
    /// the whole document leaves one empty line with the caret at the start.
    public func deleteSelectedLines() {
        textInputView.deleteSelectedLines()
    }

    /// Toggles the active language's line comment over every row touched by the current
    /// selection(s) (⌘/). Comments if any touched non-blank row lacks the prefix; otherwise
    /// uncomments. Multi-caret aware, one undo step. No-op when the language mode has no
    /// ``TreeSitterLanguage/lineCommentPrefix``.
    public func toggleComment() {
        textInputView.toggleComment()
    }

    /// Inserts a new, indent-matched blank line above every row touched by the current
    /// selection(s) (⌘⏎), one undo step, caret left on the new line(s).
    public func insertLineAbove() {
        textInputView.insertLine(above: true)
    }

    /// Inserts a new, indent-matched blank line below every row touched by the current
    /// selection(s) (⌘⇧⏎), one undo step, caret left on the new line(s).
    public func insertLineBelow() {
        textInputView.insertLine(above: false)
    }

    /// Sorts every contiguous block of rows touched by the current selection(s), ascending,
    /// case-sensitive, one undo step. A single-row block is left alone.
    public func sortSelectedLinesAscending() {
        textInputView.sortSelectedLines(descending: false)
    }

    /// Sorts every contiguous block of rows touched by the current selection(s), descending,
    /// case-sensitive, one undo step. A single-row block is left alone.
    public func sortSelectedLinesDescending() {
        textInputView.sortSelectedLines(descending: true)
    }

    /// Attempts to detect the indent strategy used in the document. This may return an unknown strategy even
    /// when the document contains indentation.
    public func detectIndentStrategy() -> DetectedIndentStrategy {
        textInputView.detectIndentStrategy()
    }

    /// Go to the beginning of the line at the specified index.
    ///
    /// - Parameter lineIndex: Index of line to navigate to.
    /// - Parameter selection: The placement of the caret on the line.
    /// - Returns: True if the text view could navigate to the specified line index, otherwise false.
    @discardableResult
    public func goToLine(_ lineIndex: Int, select selection: GoToLineSelection = .beginning) -> Bool {
        guard lineIndex >= 0 && lineIndex < textInputView.lineManager.lineCount else {
            return false
        }
        recordNavigationCheckpoint()
        // I'm not exactly sure why this is necessary but if the text view is the first responder as we jump
        // to the line and we don't resign the first responder first, the caret will disappear after we have
        // jumped to the specified line.
        resignFirstResponder()
        becomeFirstResponder()
        let line = textInputView.lineManager.line(atRow: lineIndex)
        textInputView.prepareLineForDisplay(atLocation: line.location)
        scrollLocationToVisible(line.location)
        layoutIfNeeded()
        switch selection {
        case .beginning:
            textInputView.selection = NSRange(location: line.location, length: 0)
        case .end:
            textInputView.selection = NSRange(location: line.data.length, length: line.data.length)
        case .line:
            textInputView.selection = NSRange(location: line.location, length: line.data.length)
        }
        return true
    }

    /// Search for the specified query.
    ///
    /// Synchronous; materializes file-backed buffers. Prefer ``FindSearchEngine`` with a
    /// piece-tree snapshot for large documents.
    ///
    /// The code below shows how a ``SearchQuery`` can be constructed and passed to ``search(for:)``.
    ///
    /// ```swift
    /// let query = SearchQuery(text: "foo", matchMethod: .contains, isCaseSensitive: false)
    /// let results = textView.search(for: query)
    /// ```
    ///
    /// - Parameter query: Query to find matches for.
    /// - Returns: Results matching the query.
    public func search(for query: SearchQuery) -> [SearchResult] {
        let searchController = SearchController(stringView: textInputView.stringView)
        searchController.delegate = self
        return searchController.search(for: query)
    }

    /// Search for the specified query and return results that take a replacement string into account.
    ///
    /// When searching for a regular expression this function will perform pattern matching and take the matched groups into account in the returned results.
    ///
    /// The code below shows how a ``SearchQuery`` can be constructed and passed to ``search(for:replacingMatchesWith:)`` and how the returned search results can be used to perform a replace operation.
    ///
    /// ```swift
    /// let query = SearchQuery(text: "foo", matchMethod: .contains, isCaseSensitive: false)
    /// let results = textView.search(for: query, replacingMatchesWith: "bar")
    /// let replacements = results.map { BatchReplaceSet.Replacement(range: $0.range, text: $0.replacementText) }
    /// let batchReplaceSet = BatchReplaceSet(replacements: replacements)
    /// textView.replaceText(in: batchReplaceSet)
    /// ```
    ///
    /// - Parameters:
    ///   - query: Query to find matches for.
    ///   - replacementString: String to replace matches with. Can refer to groups in a regular expression using $0, $1, $2 etc.
    /// - Returns: Results matching the query.
    public func search(for query: SearchQuery, replacingMatchesWith replacementString: String) -> [SearchReplaceResult] {
        let searchController = SearchController(stringView: textInputView.stringView)
        searchController.delegate = self
        return searchController.search(for: query, replacingMatchesWith: replacementString)
    }

    /// Returns a peek into the text view's underlying attributed string.
    /// - Parameter range: Range of text to include in text view. The returned result may span a larger range than the one specified.
    /// - Returns: Text preview containing the specified range.
    public func textPreview(containing range: NSRange) -> TextPreview? {
        textInputView.textPreview(containing: range)
    }

    /// Selects a highlighted range behind the selected range if possible.
    public func selectPreviousHighlightedRange() {
        highlightNavigationController.selectPreviousRange()
    }

    /// Selects a highlighted range after the selected range if possible.
    public func selectNextHighlightedRange() {
        highlightNavigationController.selectNextRange()
    }

    /// Selects the highlighed range at the specified index.
    /// - Parameter index: Index of highlighted range to select.
    public func selectHighlightedRange(at index: Int) {
        recordNavigationCheckpoint()
        highlightNavigationController.selectRange(at: index)
    }

    /// Shows the built-in find panel.
    public func showFindPanel(mode: FindPanelMode = .find) {
        findPanelController.show(mode: mode)
        setNeedsLayout()
    }

    /// Hides the built-in find panel.
    public func hideFindPanel() {
        findPanelController.hide()
        setNeedsLayout()
    }

    /// Toggles the built-in find panel. Bound to ⌘F / ⌥⌘F when the editor is focused.
    public func toggleFindPanel(mode: FindPanelMode = .find) {
        findPanelController.toggle(mode: mode)
        setNeedsLayout()
    }

    /// Characters drawn with a warning border even when ordinary invisible-character rendering is off.
    public var warningCharacters: Set<Character> {
        get {
            textInputView.warningCharacters
        }
        set {
            textInputView.warningCharacters = newValue
        }
    }

    /// When the page guide is shown, shades the region to the right of the guide column.
    public var showReformattingGuideShading: Bool {
        get {
            textInputView.showReformattingGuideShading
        }
        set {
            textInputView.showReformattingGuideShading = newValue
        }
    }

    /// Synchronously displays the visible lines. This can be used to immediately update the visible lines after setting the theme. Use with caution as this redisplaying the visible lines can be a costly operation.
    public func redisplayVisibleLines() {
        textInputView.redisplayVisibleLines()
    }
}

// MARK: - UITextInput
extension TextView {
    /// The range of currently marked text in a document.
    public var markedTextRange: UITextRange? {
        textInputView.markedTextRange
    }

    /// The text position for the beginning of a document.
    public var beginningOfDocument: UITextPosition {
        textInputView.beginningOfDocument
    }

    /// The text position for the end of a document.
    public var endOfDocument: UITextPosition {
        textInputView.endOfDocument
    }

    /// Returns the range between two text positions.
    /// - Parameters:
    ///   - fromPosition: An object that represents a location in a document.
    ///   - toPosition: An object that represents another location in a document.
    /// - Returns: An object that represents the range between fromPosition and toPosition.
    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        textInputView.textRange(from: fromPosition, to: toPosition)
    }

    /// Returns the text position at a specified offset from another text position.
    /// - Parameters:
    ///   - position: A custom UITextPosition object that represents a location in a document.
    ///   - offset: A character offset from position. It can be a positive or negative value.
    /// - Returns: A custom UITextPosition object that represents the location in a document that is at the specified offset from position. Returns nil if the computed text position is less than 0 or greater than the length of the backing string.
    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        textInputView.position(from: position, offset: offset)
    }

    /// Returns the text position at a specified offset in a specified direction from another text position.
    /// - Parameters:
    ///   - position: A custom UITextPosition object that represents a location in a document.
    ///   - direction: A UITextLayoutDirection constant that represents the direction of the offset from position.
    ///   - offset: A character offset from position.
    /// - Returns: Returns the text position at a specified offset in a specified direction from another text position. Returns nil if the computed text position is less than 0 or greater than the length of the backing string.
    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        textInputView.position(from: position, in: direction, offset: offset)
    }

    /// Returns how one text position compares to another text position.
    /// - Parameters:
    ///   - position: A custom object that represents a location within a document.
    ///   - other: A custom object that represents another location within a document.
    /// - Returns: A value that indicates whether the two text positions are identical or whether one is before the other.
    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        textInputView.compare(position, to: other)
    }

    /// Returns the number of UTF-16 characters between one text position and another text position.
    /// - Parameters:
    ///   - from: A custom object that represents a location within a document.
    ///   - toPosition: A custom object that represents another location within document.
    /// - Returns: The number of UTF-16 characters between fromPosition and toPosition.
    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        textInputView.offset(from: from, to: toPosition)
    }

    /// An input tokenizer that provides information about the granularity of text units.
    public var tokenizer: UITextInputTokenizer {
        textInputView.tokenizer
    }

    /// Returns the text position that is at the farthest extent in a specified layout direction within a range of text.
    /// - Parameters:
    ///   - range: A text-range object that demarcates a range of text in a document.
    ///   - direction: A constant that indicates a direction of layout (right, left, up, down).
    /// - Returns: A text-position object that identifies a location in the visible text.
    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        textInputView.position(within: range, farthestIn: direction)
    }

    /// Returns a text range from a specified text position to its farthest extent in a certain direction of layout.
    /// - Parameters:
    ///   - position: A text-position object that identifies a location in a document.
    ///   - direction: A constant that indicates a direction of layout (right, left, up, down).
    /// - Returns: A text-range object that represents the distance from position to the farthest extent in direction.
    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        textInputView.characterRange(byExtending: position, in: direction)
    }

    /// Returns the first rectangle that encloses a range of text in a document.
    /// - Parameter range: An object that represents a range of text in a document.
    /// - Returns: The first rectangle in a range of text. You might use this rectangle to draw a correction rectangle. The “first” in the name refers the rectangle enclosing the first line when the range encompasses multiple lines of text.
    public func firstRect(for range: UITextRange) -> CGRect {
        textInputView.firstRect(for: range)
    }

    /// Returns a rectangle to draw the caret at a specified insertion point.
    /// - Parameter position: An object that identifies a location in a text input area.
    /// - Returns: A rectangle that defines the area for drawing the caret.
    public func caretRect(for position: UITextPosition) -> CGRect {
        textInputView.caretRect(for: position)
    }

    /// Returns an array of selection rects corresponding to the range of text.
    /// - Parameter range: An object representing a range in a document’s text.
    /// - Returns: An array of UITextSelectionRect objects that encompass the selection.
    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        textInputView.selectionRects(for: range)
    }

    /// Returns the position in a document that is closest to a specified point.
    /// - Parameter point: A point in the view that is drawing a document’s text.
    /// - Returns: An object locating a position in a document that is closest to point.
    public func closestPosition(to point: CGPoint) -> UITextPosition? {
        textInputView.closestPosition(to: point)
    }

    /// Returns the position in a document that is closest to a specified point in a specified range.
    /// - Parameters:
    ///   - point: A point in the view that is drawing a document’s text.
    ///   - range: An object representing a range in a document’s text.
    /// - Returns: An object representing the character position in range that is closest to point.
    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        textInputView.closestPosition(to: point, within: range)
    }

    /// Returns the character or range of characters that is at a specified point in a document.
    /// - Parameter point: A point in the view that is drawing a document’s text.
    /// - Returns: An object representing a range that encloses a character (or characters) at point.
    public func characterRange(at point: CGPoint) -> UITextRange? {
        textInputView.characterRange(at: point)
    }

    /// Returns the text in the specified range.
    /// - Parameter range: A range of text in a document.
    /// - Returns: A substring of a document that falls within the specified range.
    public func text(in range: UITextRange) -> String? {
        textInputView.text(in: range)
    }

    /// A Boolean value that indicates whether the text-entry object has any text.
    public var hasText: Bool {
        textInputView.hasText
    }

    /// Scrolls the text view to reveal the text in the specified range.
    ///
    /// The function will scroll the text view as little as possible while revealing as much as possible of the specified range. It is not guaranteed that the entire range is visible after performing the scroll.
    ///
    /// - Parameters:
    ///   - range: The range of text to scroll into view.
    public func scrollRangeToVisible(_ range: NSRange) {
        // Only typeset the lines actually needed to compute the caret rects below, instead of
        // every line in the document up to range.upperBound.
        textInputView.prepareLineForDisplay(atLocation: range.lowerBound)
        if range.length > 0 {
            textInputView.prepareLineForDisplay(atLocation: range.upperBound)
        }
        justScrollRangeToVisible(range)
    }
}

private extension TextView {
    @objc private func handleTap(_ gestureRecognizer: UITapGestureRecognizer) {
        guard isSelectable else {
            return
        }
        if gestureRecognizer.state == .ended {
            resumeTypewriterScrollingAfterCaretRepositioning()
            let point = gestureRecognizer.location(in: textInputView)
            let oldSelectedRange = textInputView.selection
            textInputView.moveCaret(to: point)
            if textInputView.selection != oldSelectedRange {
                layoutIfNeeded()
            }
            if isEditable {
                installEditableInteraction()
                becomeFirstResponder()
            }
        }
    }

    @objc private func handleTextRangeAdjustmentPan(_ gestureRecognizer: UIPanGestureRecognizer) {
        // This function scroll the text view when the selected range is adjusted.
        if gestureRecognizer.state == .began {
            previousSelectedRangeDuringGestureHandling = selectedRange
        } else if gestureRecognizer.state == .changed, let previousSelectedRange = previousSelectedRangeDuringGestureHandling {
            if selectedRange.lowerBound != previousSelectedRange.lowerBound {
                // User is adjusting the lower bound (location) of the selected range.
                scrollLocationToVisible(selectedRange.lowerBound)
            } else if selectedRange.upperBound != previousSelectedRange.upperBound {
                // User is adjusting the upper bound (length) of the selected range.
                scrollLocationToVisible(selectedRange.upperBound)
            }
            previousSelectedRangeDuringGestureHandling = selectedRange
        }
    }

    private func insertLeadingComponent(of characterPair: CharacterPair, in range: NSRange) -> Bool {
        let shouldInsertCharacterPair = editorDelegate?.textView(self, shouldInsert: characterPair, in: range) ?? true
        guard shouldInsertCharacterPair else {
            return false
        }
        guard let selectedRange = textInputView.selection else {
            return false
        }
        if selectedRange.length == 0 {
            textInputView.insertText(characterPair.leading + characterPair.trailing)
            textInputView.selection = NSRange(location: range.location + characterPair.leading.count, length: 0)
            return true
        } else if let text = textInputView.text(in: selectedRange) {
            let modifiedText = characterPair.leading + text + characterPair.trailing
            let indexedRange = IndexedRange(selectedRange)
            textInputView.replace(indexedRange, withText: modifiedText)
            textInputView.selection = NSRange(location: range.location + characterPair.leading.count, length: range.length)
            return true
        } else {
            return false
        }
    }

    private func skipInsertingTrailingComponent(of characterPair: CharacterPair, in range: NSRange) -> Bool {
        // When typing the trailing component of a character pair, e.g. ) or } and the cursor is just in front of that character,
        // the delegate is asked whether the text view should skip inserting that character. If the character is skipped,
        // then the caret is moved after the trailing character component.
        let followingTextRange = NSRange(location: range.location + range.length, length: characterPair.trailing.count)
        let followingText = textInputView.text(in: followingTextRange)
        guard followingText == characterPair.trailing else {
            return false
        }
        let shouldSkip = editorDelegate?.textView(self, shouldSkipTrailingComponentOf: characterPair, in: range) ?? true
        if shouldSkip {
            moveCaret(byOffset: characterPair.trailing.count)
            return true
        } else {
            return false
        }
    }

    private func moveCaret(byOffset offset: Int) {
        if let selectedRange = textInputView.selection {
            textInputView.selection = NSRange(location: selectedRange.location + offset, length: 0)
        }
    }

    private func handleContentSizeUpdateIfNeeded() {
        if hasPendingContentSizeUpdate {
            // We don't want to update the content size when the scroll view is "bouncing" near the gutter,
            // or at the end of a line since it causes flickering when updating the content size while scrolling.
            // However, we do allow updating the content size if the text view is scrolled far enough on
            // the y-axis as that means it will soon run out of text to display.
            let isBouncingAtGutter = contentOffset.x < -contentInset.left
            let isBouncingAtLineEnd = contentOffset.x > contentSize.width - frame.size.width + contentInset.right
            let isBouncingHorizontally = isBouncingAtGutter || isBouncingAtLineEnd
            let isCriticalUpdate = contentOffset.y > contentSize.height - frame.height * 1.5
            let isScrolling = isDragging || isDecelerating
            if !isBouncingHorizontally || isCriticalUpdate || !isScrolling {
                hasPendingContentSizeUpdate = false
                // Defer contentSize/contentOffset mutation out of layoutSubviews —
                // mutating scroll metrics mid-pass trips Update Constraints in Window.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let preferred = self.preferredContentSize
                    let oldContentOffset = self.contentOffset
                    if self.contentSize != preferred {
                        self.contentSize = preferred
                        self.contentOffset = oldContentOffset
                    }
                    self.setNeedsLayout()
                }
            }
        }
    }

    private func syncContentSizeIfNeeded() {
        let preferred = preferredContentSize
        guard contentSize != preferred else {
            return
        }
        let preservedOffset = contentOffset
        contentSize = preferred
        contentOffset = preservedOffset
    }

    private func applyEffectiveTextContainerInset() {
        var effectiveInset = configuredTextContainerInset
        if isTypewriterScrollingEnabled {
            let viewportHeight = max(frame.height - adjustedContentInset.top - adjustedContentInset.bottom, 0)
            effectiveInset.top += TypewriterScrollingPolicy.requiredTopOverscroll(
                viewportHeight: viewportHeight,
                anchorFraction: typewriterAnchorFraction
            )
        }
        textInputView.textContainerInset = effectiveInset
    }

    private func applyDistractionFreeChromeVisibility(_ isVisible: Bool, duration: TimeInterval) {
        let alpha: CGFloat = isVisible ? 1 : 0
        let chromeViews: [NSView] = [
            textInputView.gutterContainerView,
            minimapView,
            findPanelController.panelView
        ]
        if duration > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for view in chromeViews {
                    view.animator().alphaValue = alpha
                }
            }
        } else {
            for view in chromeViews {
                view.alphaValue = alpha
            }
        }
        // The scrollers manage their own auto-hide opacity, so they follow the chrome through a
        // suppression flag instead of being faded directly.
        scrollerOverlay.setChromeVisible(isVisible, duration: duration)
        editorDelegate?.textView(
            self,
            didChangeDistractionFreeChromeVisibility: isVisible,
            transitionDuration: duration
        )
    }

    // Typewriter anchoring: see TypewriterScrollingPolicy.
    private func justScrollRangeToVisible(_ range: NSRange, animateTypewriter: Bool = false) {
        if TypewriterScrollingPolicy.shouldAnchor(isTypewriterScrollingEnabled: isTypewriterScrollingEnabled,
                                                  isAutomaticScrollEnabled: isAutomaticScrollEnabled,
                                                  isSuspendedByUser: isTypewriterScrollingSuspendedByUser,
                                                  rangeLength: range.length) {
            syncContentSizeIfNeeded()
            if let offset = contentOffsetForTypewriterAnchor(at: range.lowerBound) {
                let now = ProcessInfo.processInfo.systemUptime
                let isRapidMove = now - lastTypewriterCaretMoveTime < 0.12
                lastTypewriterCaretMoveTime = now
                setContentOffset(offset, animationDuration: animateTypewriter && !isRapidMove ? 0.12 : 0)
                return
            }
        }
        let lowerBoundRect = textInputView.caretRect(at: range.lowerBound)
        let upperBoundRect = range.length == 0 ? lowerBoundRect : textInputView.caretRect(at: range.upperBound)
        let rectMinX = min(lowerBoundRect.minX, upperBoundRect.minX)
        let rectMaxX = max(lowerBoundRect.maxX, upperBoundRect.maxX)
        let rectMinY = min(lowerBoundRect.minY, upperBoundRect.minY)
        let rectMaxY = max(lowerBoundRect.maxY, upperBoundRect.maxY)
        let rect = CGRect(x: rectMinX, y: rectMinY, width: rectMaxX - rectMinX, height: rectMaxY - rectMinY)
        contentOffset = contentOffsetForScrollingToVisibleRect(rect)
    }

    private func scrollLocationToVisible(_ location: Int, animateTypewriter: Bool = false) {
        let range = NSRange(location: location, length: 0)
        justScrollRangeToVisible(range, animateTypewriter: animateTypewriter)
    }

    private func installEditableInteraction() {
        isInputAccessoryViewEnabled = true
        textInputView.setSelectionOverlayEnabled(true)
    }

    private func installNonEditableInteraction() {
        isInputAccessoryViewEnabled = false
        textInputView.setSelectionOverlayEnabled(false)
    }

    private func suspendTypewriterScrollingForUserInteraction() {
        guard isTypewriterScrollingEnabled else {
            return
        }
        isTypewriterScrollingSuspendedByUser = true
    }

    private func resumeTypewriterScrollingAfterKeyPress() {
        isTypewriterScrollingSuspendedByUser = false
    }

    private func reanchorTypewriterCaretIfNeeded() {
        guard isTypewriterScrollingEnabled, isAutomaticScrollEnabled else {
            return
        }
        guard !isTypewriterScrollingSuspendedByUser else {
            return
        }
        guard let selection = textInputView.selection, selection.length == 0 else {
            return
        }
        let location = selection.location
        DispatchQueue.main.async { [weak self] in
            self?.scrollLocationToVisible(location)
        }
    }

    private func scrollViewport(at offset: CGPoint) -> CGRect {
        var viewport = CGRect(x: offset.x, y: offset.y, width: frame.width, height: frame.height)
        viewport.origin.y += adjustedContentInset.top
        viewport.origin.x += adjustedContentInset.left + gutterWidth
        viewport.size.width -= adjustedContentInset.left + adjustedContentInset.right + gutterWidth
        viewport.size.height -= adjustedContentInset.top + adjustedContentInset.bottom
        return viewport
    }

    private func applyHorizontalScrollReveal(for rect: CGRect, viewport: CGRect, into contentOffset: inout CGPoint) {
        if rect.minX < viewport.minX {
            contentOffset.x -= viewport.minX - rect.minX
        } else if rect.maxX > viewport.maxX && rect.width <= viewport.width {
            contentOffset.x += rect.maxX - viewport.maxX
        } else if rect.maxX > viewport.maxX {
            contentOffset.x += rect.minX
        }
    }

    private func contentOffsetForTypewriterAnchor(at location: Int) -> CGPoint? {
        textInputView.prepareLineForDisplay(atLocation: location)
        guard let anchorY = textInputView.lineAnchorY(at: location) else {
            return nil
        }
        let caretRect = textInputView.caretRect(at: location)
        let viewport = scrollViewport(at: contentOffset)
        var newContentOffset = contentOffset
        applyHorizontalScrollReveal(for: caretRect, viewport: viewport, into: &newContentOffset)
        newContentOffset.y = anchorY - adjustedContentInset.top - viewport.height * typewriterAnchorFraction
        let cappedXOffset = min(max(newContentOffset.x, minimumContentOffset.x), maximumContentOffset.x)
        let cappedYOffset = min(max(newContentOffset.y, minimumContentOffset.y), maximumContentOffset.y)
        return CGPoint(x: cappedXOffset, y: cappedYOffset)
    }

    /// Computes a content offset to scroll to in order to reveal the specified rectangle.
    ///
    /// The function will return a rectangle that scrolls the text view a minimum amount while revealing as much as possible of the rectangle. It is not guaranteed that the entire rectangle can be revealed.
    /// - Parameter rect: The rectangle to reveal.
    /// - Returns: The content offset to scroll to.
    private func contentOffsetForScrollingToVisibleRect(_ rect: CGRect) -> CGPoint {
        let viewport = scrollViewport(at: contentOffset)
        var newContentOffset = contentOffset
        applyHorizontalScrollReveal(for: rect, viewport: viewport, into: &newContentOffset)
        if rect.minY < viewport.minY {
            newContentOffset.y -= viewport.minY - rect.minY
        } else if rect.maxY > viewport.maxY && rect.height <= viewport.height {
            // The end of the rectangle is not visible and the rect fits within the screen so we'll scroll to reveal the entire rect.
            newContentOffset.y += rect.maxY - viewport.maxY
        } else if rect.maxY > viewport.maxY {
            newContentOffset.y += rect.minY
        }
        let cappedXOffset = min(max(newContentOffset.x, minimumContentOffset.x), maximumContentOffset.x)
        let cappedYOffset = min(max(newContentOffset.y, minimumContentOffset.y), maximumContentOffset.y)
        return CGPoint(x: cappedXOffset, y: cappedYOffset)
    }
}

extension TextView {
    func resumeTypewriterScrollingAfterCaretRepositioning() {
        isTypewriterScrollingSuspendedByUser = false
    }
}

// MARK: - TextInputViewDelegate
extension TextView: TextInputViewDelegate {
    func textInputViewWillBeginEditing(_ view: TextInputView) {
        guard isEditable else {
            return
        }
        isEditing = true
        // If a developer is programmatically calling becomeFirstresponder() then we might not have a selected range.
        // We set the selectedRange instead of the selectedTextRange to avoid invoking any delegates.
        if textInputView.selection == nil {
            textInputView.selection = NSRange(location: 0, length: 0)
        }
        // Ensure selection is marked dirty without forcing a nested AppKit layout pass.
        textInputView.setNeedsLayout()
        installEditableInteraction()
    }

    func textInputViewDidBeginEditing(_ view: TextInputView) {
        editorDelegate?.textViewDidBeginEditing(self)
    }

    func textInputViewDidCancelBeginEditing(_ view: TextInputView) {
        isEditing = false
        installNonEditableInteraction()
    }

    func textInputViewDidEndEditing(_ view: TextInputView) {
        isEditing = false
        installNonEditableInteraction()
        editorDelegate?.textViewDidEndEditing(self)
    }

    func textInputViewDidChange(_ view: TextInputView) {
        setNeedsLayout()
        if isAutomaticScrollEnabled, let newRange = textInputView.selection, newRange.length == 0 {
            let location = newRange.location
            DispatchQueue.main.async { [weak self] in
                self?.scrollLocationToVisible(location, animateTypewriter: true)
            }
        }
        if showMinimap {
            minimapView.setNeedsDisplayForContentChange()
        }
        findPanelController.refreshIfVisible()
        if let selection = textInputView.selection {
            highlightProviderCoordinator?.applyEdit(in: selection, delta: 0)
        }
        editorDelegate?.textViewDidChange(self)
    }

    func textInputViewDidChangeSelection(_ view: TextInputView) {
        UIMenuController.shared.hideMenu(from: self)
        if !isApplyingHistoryNavigation {
            navigationHistory.noteCursor(currentNavigationEntry())
        }
        highlightNavigationController.selectedRange = view.selection
        if isAutomaticScrollEnabled, let newRange = textInputView.selection, newRange.length == 0 {
            // Never mutate contentOffset synchronously from selection changes —
            // this often fires during layoutSubviews / setState from SwiftUI.
            let location = newRange.location
            DispatchQueue.main.async { [weak self] in
                self?.scrollLocationToVisible(location, animateTypewriter: true)
            }
        }
        editorDelegate?.textViewDidChangeSelection(self)
    }

    func textInputViewDidInvalidateContentSize(_ view: TextInputView) {
        if contentSize != view.contentSize {
            hasPendingContentSizeUpdate = true
            setNeedsLayout()
        }
    }

    func textInputViewDidRequestLayoutFlush(_ view: TextInputView) {
        guard !deferredInputLayoutFlushScheduled else {
            return
        }
        deferredInputLayoutFlushScheduled = true
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view else {
                return
            }
            self.deferredInputLayoutFlushScheduled = false

            // SwiftUI/AppKit can mark only the document view dirty after an edit. Drive the outer
            // scroll view first so its viewport and document frame are current, then synchronously
            // apply the content-size result produced by that pass and lay out once more. Presenting
            // before this outer pass is the Return/new-line bug: renderer state advances while the
            // fixed Metal overlay remains on the previous scroll geometry until a resize.
            self.setNeedsLayout()
            self.layoutSubtreeIfNeeded()
            self.syncContentSizeIfNeeded()
            self.setNeedsLayout()
            self.layoutSubtreeIfNeeded()
            view.performDeferredLayoutFlush()
        }
    }

    func textInputView(_ view: TextInputView, didProposeContentOffsetAdjustment contentOffsetAdjustment: CGPoint) {
        let isScrolling = isDragging || isDecelerating
        if contentOffsetAdjustment != .zero && isScrolling {
            // LayoutManager proposes this from inside layoutLinesInViewport —
            // never mutate contentOffset synchronously mid-layout.
            let adjustment = contentOffsetAdjustment
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.contentOffset = CGPoint(
                    x: self.contentOffset.x + adjustment.x,
                    y: self.contentOffset.y + adjustment.y
                )
            }
        }
    }

    func textInputView(_ view: TextInputView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if textInputView.isRestoringPreviouslyDeletedText {
            // UIKit is inserting text to combine characters, for example to combine two Korean characters into one, and we do not want to interfere with that.
            return editorDelegate?.textView(self, shouldChangeTextIn: range, replacementText: text) ?? true
        } else if let characterPair = characterPairs.first(where: { $0.trailing == text }),
                    skipInsertingTrailingComponent(of: characterPair, in: range) {
            return false
        } else if let characterPair = characterPairs.first(where: { $0.leading == text }), insertLeadingComponent(of: characterPair, in: range) {
            return false
        } else {
            return editorDelegate?.textView(self, shouldChangeTextIn: range, replacementText: text) ?? true
        }
    }

    func textInputViewDidChangeGutterWidth(_ view: TextInputView) {
        editorDelegate?.textViewDidChangeGutterWidth(self)
    }

    func textInputViewDidBeginFloatingCursor(_ view: TextInputView) {
        editorDelegate?.textViewDidBeginFloatingCursor(self)
    }

    func textInputViewDidEndFloatingCursor(_ view: TextInputView) {
        editorDelegate?.textViewDidEndFloatingCursor(self)
    }

    func textInputViewDidUpdateMarkedRange(_ view: TextInputView) {
        textInputView.enableSelectionCursorBlinks()
    }

    func textInputView(_ view: TextInputView, canReplaceTextIn highlightedRange: HighlightedRange) -> Bool {
        editorDelegate?.textView(self, canReplaceTextIn: highlightedRange) ?? false
    }

    func textInputView(_ view: TextInputView, replaceTextIn highlightedRange: HighlightedRange) {
        editorDelegate?.textView(self, replaceTextIn: highlightedRange)
    }

    func textInputViewIsSelectable(_ view: TextInputView) -> Bool {
        isSelectable
    }

    func textInputViewIsEditable(_ view: TextInputView) -> Bool {
        isEditable
    }

    func textInputView(_ view: TextInputView, didRequestSelectionInteraction enabled: Bool) {
        if enabled && isSelectable {
            textInputView.setSelectionOverlayEnabled(true)
        }
    }

    func textInputViewDidRequestToggleFindPanel(_ view: TextInputView, mode: FindPanelMode) {
        toggleFindPanel(mode: mode)
    }

    func textInputView(_ view: TextInputView, shouldInterceptKeyDown event: NSEvent) -> Bool {
        if keyDownHandler?(event) == true {
            return true
        }
        for interceptor in keyDownInterceptors where interceptor(event) {
            return true
        }
        return false
    }

    func textInputView(_ view: TextInputView, didRequestAction action: EditorActionID) -> Bool {
        if let handler = editorActionHandler, handler(action) {
            return true
        }
        switch action {
        case .navigateBack:
            return navigateBack()
        case .navigateForward:
            return navigateForward()
        default:
            return false
        }
    }

    func textInputView(_ view: TextInputView, didReceiveKeyDown event: NSEvent) {
        distractionFreeController.typingDidBegin()
        if isTypewriterScrollingSuspendedByUser {
            resumeTypewriterScrollingAfterKeyPress()
        }
    }

    func textInputViewDidReceiveCaretRepositioningClick(_ view: TextInputView) {
        resumeTypewriterScrollingAfterCaretRepositioning()
    }

    func textInputViewDidFinishSyntaxParse(_ view: TextInputView) {
        if showMinimap {
            minimapView.invalidateSyntaxColors()
            minimapView.setNeedsDisplayForContentChange()
        }
        editorDelegate?.textViewDidFinishSyntaxParse(self)
    }

    func textInputView(_ view: TextInputView, didChangeContent change: TextContentChange) {
        editorDelegate?.textView(self, didChangeContent: change)
    }
}

extension TextView {
    /// UTF-8 write of the live buffer. File-backed documents stream piece UTF-8; they do not
    /// materialize ``text``. Throws ``DocumentWriteError/unsupportedEncoding`` unless UTF-8.
    ///
    /// On success, inspect ``DocumentWriteResult/generationMatched``: if the user typed during
    /// the write this is `false` and the live buffer is ahead of `url`.
    public func write(
        to url: URL,
        options: DocumentWriteOptions = .init(),
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> DocumentWriteResult {
        try await writeLock.acquire()
        defer { writeLock.release() }
        if Task.isCancelled {
            throw DocumentWriteError.cancelled
        }
        let (source, generation, identity) = captureWriteSource()
        let footer: DocumentWriteFooter
        do {
            let writer = Task.detached(priority: .userInitiated) {
                try DocumentWriter.write(source, to: url, options: options, progress: progress)
            }
            footer = try await withTaskCancellationHandler {
                try await writer.value
            } onCancel: {
                writer.cancel()
            }
        } catch is CancellationError {
            throw DocumentWriteError.cancelled
        }
        return finishWrite(source: source, generation: generation, identity: identity, footer: footer, url: url)
    }

    private func captureWriteSource() -> (DocumentWriteSource, UInt64, ObjectIdentifier) {
        let stringView = textInputView.stringView
        let generation = stringView.contentGeneration
        let identity = ObjectIdentifier(stringView)
        if let snapshot = stringView.contentSnapshot() {
            return (.pieceTree(snapshot), generation, identity)
        }
        return (.contiguous(stringView.string as String), generation, identity)
    }

    private func finishWrite(
        source: DocumentWriteSource,
        generation: UInt64,
        identity: ObjectIdentifier,
        footer: DocumentWriteFooter,
        url: URL
    ) -> DocumentWriteResult {
        let live = textInputView.stringView
        let generationMatched = ObjectIdentifier(live) == identity && live.contentGeneration == generation
        var compacted = false
        if generationMatched, case .pieceTree = source {
            if let mapping = FileMapping.openPrivateClone(of: url) {
                live.compactPieceTree(mapping: mapping, footer: footer)
                compacted = true
            }
        }
        return DocumentWriteResult(
            wroteBytes: Int64(footer.utf8Length),
            generationMatched: generationMatched,
            compacted: compacted
        )
    }
}

// MARK: - HighlightNavigationControllerDelegate
extension TextView: HighlightNavigationControllerDelegate {
    func highlightNavigationController(_ controller: HighlightNavigationController,
                                       shouldNavigateTo highlightNavigationRange: HighlightNavigationRange) {
        let range = highlightNavigationRange.range
        scrollRangeToVisible(range)
        textInputView.selectedTextRange = IndexedRange(range)
        _ = textInputView.becomeFirstResponder()
        if showMenuAfterNavigatingToHighlightedRange {
            textInputView.presentEditMenuForText(in: range)
        }
        switch highlightNavigationRange.loopMode {
        case .previousGoesToLast:
            editorDelegate?.textViewDidLoopToLastHighlightedRange(self)
        case .nextGoesToFirst:
            editorDelegate?.textViewDidLoopToFirstHighlightedRange(self)
        case .disabled:
            break
        }
    }
}

// MARK: - FindPanelTarget
extension TextView: FindPanelTarget {
    var findPanelTargetView: NSView {
        self
    }

    var findSelection: NSRange? {
        textInputView.selection
    }

    var findTextSource: any FindTextSource {
        makeFindTextSource()
    }

    func selectedTextForFind() -> String? {
        guard let range = textInputView.selection, range.length > 0 else {
            return nil
        }
        return textInputView.text(in: range)
    }

    func setSelectedRange(_ range: NSRange) {
        textInputView.selection = range
    }

    func findPanelWillShow(panelHeight: CGFloat) {
        setFindPanelTopInset(panelHeight)
    }

    func findPanelWillHide(panelHeight: CGFloat) {
        setFindPanelTopInset(0)
    }

    /// Grows or shrinks the space reserved for the top-anchored find bar, translating
    /// `contentOffset` by exactly the change so already-visible text stays visible — pushed down
    /// (or back up) by the bar rather than left to scroll out from under it. Also covers the
    /// Find ↔ Replace mode toggle, which changes `panelHeight` while the bar is already showing,
    /// by reading the *current* `findPanelTopInset` rather than assuming a fresh open from zero.
    private func setFindPanelTopInset(_ newInset: CGFloat) {
        let delta = newInset - findPanelTopInset
        findPanelTopInset = newInset
        guard delta != 0 else {
            setNeedsLayout()
            return
        }
        let clampedY = min(max(contentOffset.y - delta, minimumContentOffset.y), maximumContentOffset.y)
        contentOffset = CGPoint(x: contentOffset.x, y: clampedY)
        setNeedsLayout()
    }

    func findPanelModeDidChange(to mode: FindPanelMode) {
        setNeedsLayout()
    }
}

// MARK: - SearchControllerDelegate
extension TextView: SearchControllerDelegate {
    func searchController(_ searchController: SearchController, linePositionAt location: Int) -> LinePosition? {
        textInputView.lineManager.linePosition(at: location)
    }
}

// MARK: - UIGestureRecognizerDelegate
extension TextView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if let klass = NSClassFromString("UITextRangeAdjustmentGestureRecognizer") {
            if !textRangeAdjustmentGestureRecognizers.contains(otherGestureRecognizer) && otherGestureRecognizer.isKind(of: klass) {
                otherGestureRecognizer.addTarget(self, action: #selector(handleTextRangeAdjustmentPan(_:)))
                textRangeAdjustmentGestureRecognizers.insert(otherGestureRecognizer)
            }
        }
        return gestureRecognizer !== panGestureRecognizer
    }
}

// MARK: - KeyboardObserverDelegate
extension TextView: KeyboardObserverDelegate {
    public func keyboardObserver(_ keyboardObserver: KeyboardObserver,
                          keyboardWillShowWithHeight keyboardHeight: CGFloat,
                          animation: KeyboardObserver.Animation?) {
        if isAutomaticScrollEnabled, let newRange = textInputView.selection, newRange.length == 0 {
            scrollRangeToVisible(newRange)
        }
    }
}

// swiftlint:enable type_body_length
