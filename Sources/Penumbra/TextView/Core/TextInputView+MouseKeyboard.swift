@preconcurrency import AppKit
import Foundation

extension TextInputView {
    override func mouseDown(with event: NSEvent) {
        guard delegate?.textInputViewIsSelectable(self) ?? true else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        // `becomeFirstResponder()` alone does not install first-responder status in
        // AppKit — only `NSWindow.makeFirstResponder(_:)` does. Call it unconditionally
        // (for both editable and read-only) rather than only when already first responder.
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        delegate?.textInputViewDidReceiveCaretRepositioningClick(self)
        if !(delegate?.textInputViewIsEditable(self) ?? true) {
            delegate?.textInputView(self, didRequestSelectionInteraction: true)
        }
        isMouseSelecting = true
        pendingOptionClickPoint = nil
        doubleShiftDetector.noteOtherInput()
        if isPointOnSelectionHandle(point) {
            return
        }
        let isEditable = delegate?.textInputViewIsEditable(self) ?? true
        if event.modifierFlags.contains(.option), event.modifierFlags.contains(.shift), isEditable {
            // Option+Shift extends the active block selection (or starts one from the current
            // caret if none is active yet) — distinct from plain Shift, which is checked below
            // and extends a linear selection instead. Checked first since Shift alone would
            // otherwise win this modifier combination.
            beginBlockSelectionAtCurrentCaretIfNeeded()
            extendBlockSelection(to: point)
        } else if event.modifierFlags.contains(.shift) {
            collapseMultiSelectionToPrimary()
            let anchor = selectionAnchor ?? selection?.location ?? 0
            if let index = characterIndex(at: point) {
                setSelectedRange(from: anchor, to: index)
            }
        } else if event.modifierFlags.contains(.option), event.clickCount == 1, isEditable {
            // Deferred: a plain click (no drag before mouseUp) resolves into the existing
            // add-a-caret behavior; mouseDragged promotes it into a fresh block selection instead.
            pendingOptionClickPoint = point
        } else if event.clickCount >= 3 {
            selectParagraph(at: point)
            selectionAnchor = selection?.location
        } else if event.clickCount == 2 {
            selectWord(at: point)
            selectionAnchor = selection?.location
        } else if let index = characterIndex(at: point) {
            selectionAnchor = index
            selection = NSRange(location: index, length: 0)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isMouseSelecting, delegate?.textInputViewIsSelectable(self) ?? true else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let pendingPoint = pendingOptionClickPoint {
            pendingOptionClickPoint = nil
            beginBlockSelection(at: pendingPoint)
            extendBlockSelection(to: point)
            return
        }
        if blockSelectionController.isActive {
            extendBlockSelection(to: point)
            return
        }
        collapseMultiSelectionToPrimary()
        let anchor = selectionAnchor ?? selection?.location ?? 0
        if let index = characterIndex(at: point) {
            setSelectedRange(from: anchor, to: index)
        }
    }

    override func mouseUp(with event: NSEvent) {
        isMouseSelecting = false
        if let pendingPoint = pendingOptionClickPoint {
            pendingOptionClickPoint = nil
            if let index = characterIndex(at: pendingPoint) {
                addSelection(at: index)
                selectionAnchor = index
            }
        }
        if selection?.length == 0 {
            selectionAnchor = selection?.location
        }
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard delegate?.textInputViewIsSelectable(self) ?? true else {
            super.rightMouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        // Mirror `mouseDown`: take first responder for editable *and* read-only panes, and
        // switch a read-only pane's selection overlay on. Without this a right-click that
        // lands before any left-click leaves the overlay disabled, so "Select All" (and any
        // other selecting item) from the context menu updates the model range but never
        // paints a highlight.
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        if !(delegate?.textInputViewIsEditable(self) ?? true) {
            delegate?.textInputView(self, didRequestSelectionInteraction: true)
        }
        if let index = characterIndex(at: point) {
            if selection?.contains(index) != true {
                selection = NSRange(location: index, length: 0)
            }
        }
        showContextMenu(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Not selectable at all (e.g. a plain label-like use) — behave exactly as before.
        guard delegate?.textInputViewIsSelectable(self) ?? true else {
            super.keyDown(with: event)
            return
        }
        // Read-only panes still get caret navigation, shift-selection and ⌘A/⌘C —
        // the same as a non-editable, selectable NSTextView — but no mutation.
        let isEditable = delegate?.textInputViewIsEditable(self) ?? true

        // While composing marked text, let the input context own every key.
        // Otherwise navigation/delete must be handled locally first:
        // NSTextInputContext.handleEvent returns true for those keys and then
        // calls doCommand(by:), which previously had no implementation — so
        // arrows and Backspace were swallowed while insertText still worked.
        if hasMarkedText(), inputContext?.handleEvent(event) == true {
            return
        }

        delegate?.textInputView(self, didReceiveKeyDown: event)
        // A key press cancels a half-formed double-modifier tap (e.g. ⇧ x ⇧).
        doubleShiftDetector.noteOtherInput()

        if delegate?.textInputView(self, shouldInterceptKeyDown: event) == true {
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ⌘A stays hard-wired: it is the standard Select All and is intentionally matched
        // loosely (any ⌘ + "a"), unlike the exact-modifier keymap bindings.
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" {
            selectAll(nil)
            return
        }

        switch keymapDispatcher.resolve(event: event, keymap: keymap) {
        case .pendingChord:
            return
        case .action(let action):
            if performKeymapAction(action, isEditable: isEditable) {
                return
            }
            if delegate?.textInputView(self, didRequestAction: action) == true {
                return
            }
            // Neither core nor host handled it — try a built-in fallback, then swallow so the
            // key doesn't fall through to text insertion.
            _ = performFallbackAction(action, isEditable: isEditable)
            return
        case .unhandled:
            break
        }

        // Sticky column-selection mode (⌘⇧8): arrows grow the rectangle, Esc is handled below.
        if blockSelectionController.isStickyModeEnabled {
            switch event.keyCode {
            case 0x7B:
                extendBlockSelection(in: .left)
                return
            case 0x7C:
                extendBlockSelection(in: .right)
                return
            case 0x7D:
                extendBlockSelection(in: .down)
                return
            case 0x7E:
                extendBlockSelection(in: .up)
                return
            default:
                break
            }
        }

        // ⌃⇧←/→/↑/↓ grow/shrink a block selection. Checked before the plain arrow-key switch
        // below, where ⇧ already means linear selection extension. Not expressed through the
        // keymap because it is a continuous directional gesture, not a discrete action.
        if flags == [.control, .shift] {
            switch event.keyCode {
            case 0x7B:
                extendBlockSelection(in: .left)
                return
            case 0x7C:
                extendBlockSelection(in: .right)
                return
            case 0x7D:
                extendBlockSelection(in: .down)
                return
            case 0x7E:
                extendBlockSelection(in: .up)
                return
            default:
                break
            }
        }

        switch event.keyCode {
        case 0x30 where isEditable && hasActiveSnippetSession:
            if flags.contains(.shift) {
                _ = retreatSnippetSession()
            } else {
                _ = advanceSnippetSession()
            }
            return
        case 0x7B:
            moveSelectionForArrowKey(direction: .left, flags: flags)
            return
        case 0x7C:
            moveSelectionForArrowKey(direction: .right, flags: flags)
            return
        case 0x7D:
            moveSelectionForArrowKey(direction: .down, flags: flags)
            return
        case 0x7E:
            moveSelectionForArrowKey(direction: .up, flags: flags)
            return
        case 0x73:
            moveSelectionToBoundary(.line, direction: .backward, extending: flags.contains(.shift))
            return
        case 0x77:
            moveSelectionToBoundary(.line, direction: .forward, extending: flags.contains(.shift))
            return
        case 0x33 where isEditable:
            if flags.contains(.option) {
                deleteWord(backward: true)
            } else {
                deleteBackward()
            }
            return
        case 0x75 where isEditable:
            if flags.contains(.option) {
                deleteWord(backward: false)
            } else {
                deleteForward()
            }
            return
        case 0x35:
            if blockSelectionController.isActive {
                endBlockSelection()
                collapseMultiSelectionToPrimary()
                return
            }
            if isMultiCursorActive {
                collapseMultiSelectionToPrimary()
                return
            }
            if hasActiveSnippetSession {
                cancelSnippetSession()
                return
            }
        default:
            break
        }

        // Everything below mutates or inserts text — only while editable.
        guard isEditable else {
            super.keyDown(with: event)
            return
        }

        if inputContext?.handleEvent(event) == true {
            return
        }

        if let characters = event.characters, !characters.isEmpty, shouldInsert(characters: characters, flags: flags) {
            insertText(characters)
        } else {
            super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        onFlagsChanged?(event)
        if doubleShiftDetector.handleFlagsChanged(event) {
            if performKeymapAction(.searchEverywhere, isEditable: delegate?.textInputViewIsEditable(self) ?? true)
                || delegate?.textInputView(self, didRequestAction: .searchEverywhere) == true {
                return
            }
        }
        super.flagsChanged(with: event)
    }

    override func doCommand(by selector: Selector) {
        let isEditable = delegate?.textInputViewIsEditable(self) ?? true
        switch selector {
        case #selector(deleteBackward(_:)) where isEditable:
            deleteBackward()
        case #selector(deleteForward(_:)) where isEditable:
            deleteForward()
        case #selector(moveLeft(_:)):
            moveSelectionForArrowKey(direction: .left, flags: [])
        case #selector(moveRight(_:)):
            moveSelectionForArrowKey(direction: .right, flags: [])
        case #selector(moveUp(_:)):
            moveSelectionForArrowKey(direction: .up, flags: [])
        case #selector(moveDown(_:)):
            moveSelectionForArrowKey(direction: .down, flags: [])
        case #selector(moveLeftAndModifySelection(_:)):
            moveSelectionForArrowKey(direction: .left, flags: .shift)
        case #selector(moveRightAndModifySelection(_:)):
            moveSelectionForArrowKey(direction: .right, flags: .shift)
        case #selector(moveUpAndModifySelection(_:)):
            moveSelectionForArrowKey(direction: .up, flags: .shift)
        case #selector(moveDownAndModifySelection(_:)):
            moveSelectionForArrowKey(direction: .down, flags: .shift)
        case #selector(moveWordLeft(_:)):
            moveSelectionForArrowKey(direction: .left, flags: .option)
        case #selector(moveWordRight(_:)):
            moveSelectionForArrowKey(direction: .right, flags: .option)
        case #selector(moveWordLeftAndModifySelection(_:)):
            moveSelectionForArrowKey(direction: .left, flags: [.option, .shift])
        case #selector(moveWordRightAndModifySelection(_:)):
            moveSelectionForArrowKey(direction: .right, flags: [.option, .shift])
        case #selector(moveToBeginningOfLine(_:)):
            moveSelectionToBoundary(.line, direction: .backward, extending: false)
        case #selector(moveToEndOfLine(_:)):
            moveSelectionToBoundary(.line, direction: .forward, extending: false)
        case #selector(moveToBeginningOfLineAndModifySelection(_:)):
            moveSelectionToBoundary(.line, direction: .backward, extending: true)
        case #selector(moveToEndOfLineAndModifySelection(_:)):
            moveSelectionToBoundary(.line, direction: .forward, extending: true)
        case #selector(insertNewline(_:)) where isEditable, #selector(insertNewlineIgnoringFieldEditor(_:)) where isEditable:
            insertText("\n")
        case #selector(insertTab(_:)) where isEditable:
            if advanceSnippetSession() {
                break
            }
            insertText("\t")
        case #selector(insertBacktab(_:)) where isEditable:
            if retreatSnippetSession() {
                break
            }
            super.doCommand(by: selector)
        case #selector(cancelOperation(_:)):
            if hasActiveSnippetSession {
                cancelSnippetSession()
                break
            }
            super.doCommand(by: selector)
        default:
            super.doCommand(by: selector)
        }
    }
}

extension TextInputView {
    private func setSelectedRange(from anchor: Int, to index: Int) {
        let start = min(anchor, index)
        let end = max(anchor, index)
        inputDelegate?.selectionWillChange(self)
        selection = NSRange(location: start, length: end - start)
        inputDelegate?.selectionDidChange(self)
    }

    private func selectWord(at point: CGPoint) {
        guard let position = closestPosition(to: point) else {
            return
        }
        let start = tokenizer.position(from: position, toBoundary: .word, inDirection: .backward) ?? position
        let end = tokenizer.position(from: position, toBoundary: .word, inDirection: .forward) ?? position
        guard let startIndex = (start as? IndexedPosition)?.index,
              let endIndex = (end as? IndexedPosition)?.index else {
            return
        }
        inputDelegate?.selectionWillChange(self)
        selection = NSRange(location: startIndex, length: endIndex - startIndex)
        inputDelegate?.selectionDidChange(self)
    }

    private func selectParagraph(at point: CGPoint) {
        guard let position = closestPosition(to: point) else {
            return
        }
        let start = tokenizer.position(from: position, toBoundary: .paragraph, inDirection: .backward) ?? position
        let end = tokenizer.position(from: position, toBoundary: .paragraph, inDirection: .forward) ?? position
        guard let startIndex = (start as? IndexedPosition)?.index,
              let endIndex = (end as? IndexedPosition)?.index else {
            return
        }
        inputDelegate?.selectionWillChange(self)
        selection = NSRange(location: startIndex, length: endIndex - startIndex)
        inputDelegate?.selectionDidChange(self)
    }

    /// Performs a keymap action the editor core owns. Returns `false` for actions that need a
    /// host (palette, LSP navigation, formatting) so the delegate gets a chance at them.
    func performKeymapAction(_ action: EditorActionID, isEditable: Bool) -> Bool {
        switch action {
        case .selectLines:
            selectLines()
        case .selectNextOccurrence:
            selectNextOccurrence()
        case .selectAllOccurrences:
            selectAllOccurrences()
        case .skipCurrentOccurrence:
            skipCurrentOccurrence()
        case .addCaretsToLineEnds:
            addSelectionsOnEachLine()
        case .addCaretAbove:
            addCaretAbove()
        case .addCaretBelow:
            addCaretBelow()
        case .undoLastCaretChange:
            undoLastCaretChange()
        case .expandSelection:
            expandSemanticSelection()
        case .shrinkSelection:
            shrinkSemanticSelection()
        case .toggleColumnSelectionMode:
            toggleColumnSelectionMode()
        case .toggleFindPanel:
            delegate?.textInputViewDidRequestToggleFindPanel(self, mode: .find)
        case .toggleReplacePanel:
            delegate?.textInputViewDidRequestToggleFindPanel(self, mode: .replace)
        case .duplicateLines:
            guard isEditable else { return true }
            duplicateSelectedLines()
        case .deleteLines:
            guard isEditable else { return true }
            deleteSelectedLines()
        case .moveLineUp:
            guard isEditable else { return true }
            moveSelectedLinesUp()
        case .moveLineDown:
            guard isEditable else { return true }
            moveSelectedLinesDown()
        case .moveStatementUp:
            guard isEditable else { return true }
            moveSelectedStatements(byOffset: -1)
        case .moveStatementDown:
            guard isEditable else { return true }
            moveSelectedStatements(byOffset: 1)
        case .joinLines:
            guard isEditable else { return true }
            joinSelectedLines()
        case .indentLines:
            guard isEditable else { return true }
            shiftRight()
        case .outdentLines:
            guard isEditable else { return true }
            shiftLeft()
        case .toggleComment:
            guard isEditable else { return true }
            toggleComment()
        case .insertLineAbove:
            guard isEditable else { return true }
            insertLine(above: true)
        case .insertLineBelow:
            guard isEditable else { return true }
            insertLine(above: false)
        case .sortLinesAscending:
            guard isEditable else { return true }
            sortSelectedLines(descending: false)
        case .sortLinesDescending:
            guard isEditable else { return true }
            sortSelectedLines(descending: true)
        default:
            // Not a core action (palette, navigation, formatting, surround-with…).
            return false
        }
        return true
    }

    /// Built-in fallbacks for actions no host handled — currently a local reindent when there
    /// is no LSP formatter.
    func performFallbackAction(_ action: EditorActionID, isEditable: Bool) -> Bool {
        guard isEditable else { return false }
        switch action {
        case .reformatCode:
            reindentSelectedLines()
            return true
        default:
            return false
        }
    }

    private func moveSelectionForArrowKey(direction: UITextLayoutDirection, flags: NSEvent.ModifierFlags) {
        if flags.contains(.shift), isMultiCursorActive {
            collapseMultiSelectionToPrimary()
        }
        if !flags.contains(.shift), isMultiCursorActive {
            moveAllSelections(in: direction)
            return
        }
        if flags.contains(.command) {
            moveSelectionToBoundary(.line, direction: layoutDirectionToTextDirection(direction), extending: flags.contains(.shift))
        } else if flags.contains(.option) {
            moveSelectionToBoundary(.word, direction: layoutDirectionToTextDirection(direction), extending: flags.contains(.shift))
        } else {
            moveSelectionByCharacter(in: direction, extending: flags.contains(.shift))
        }
    }

    private func layoutDirectionToTextDirection(_ direction: UITextLayoutDirection) -> UITextDirection {
        switch direction {
        case .left, .up:
            return .backward
        case .right, .down:
            return .forward
        @unknown default:
            return .forward
        }
    }

    /// Anchor (fixed end) and active end (the end keyboard navigation moves) of the
    /// current selection. Falls back to treating `location` as the anchor when
    /// `selectionAnchor` doesn't match either bound — e.g. after a programmatic
    /// `selectedRange` assignment from find/go-to that didn't update the anchor.
    private var selectionEnds: (anchor: Int, active: Int)? {
        guard let selection else {
            return nil
        }
        guard selection.length > 0 else {
            return (selection.location, selection.location)
        }
        if selectionAnchor == selection.upperBound {
            return (selection.upperBound, selection.location)
        }
        return (selection.location, selection.upperBound)
    }

    private func moveSelectionByCharacter(in direction: UITextLayoutDirection, extending: Bool) {
        guard let currentRange = selection else {
            return
        }
        if extending {
            guard let ends = selectionEnds else {
                return
            }
            let referencePosition = IndexedPosition(index: ends.active)
            guard let newPosition = position(from: referencePosition, in: direction, offset: 1) as? IndexedPosition else {
                return
            }
            updateSelection(anchor: ends.anchor, activeLocation: newPosition.index, extending: true)
            return
        }
        // A non-empty selection collapses to its near edge without moving further,
        // matching NSTextView. Only an already-empty caret moves by one character.
        if currentRange.length > 0 {
            let collapseIndex = direction == .left || direction == .up ? currentRange.location : currentRange.upperBound
            updateSelection(anchor: collapseIndex, activeLocation: collapseIndex, extending: false)
            return
        }
        let referencePosition = IndexedPosition(index: currentRange.location)
        guard let newPosition = position(from: referencePosition, in: direction, offset: 1) as? IndexedPosition else {
            return
        }
        updateSelection(anchor: newPosition.index, activeLocation: newPosition.index, extending: false)
    }

    private func moveSelectionToBoundary(_ granularity: UITextGranularity,
                                       direction: UITextDirection,
                                       extending: Bool) {
        guard let currentRange = selection else {
            return
        }
        if extending {
            guard let ends = selectionEnds else {
                return
            }
            let position = IndexedPosition(index: ends.active)
            guard let boundary = tokenizer.position(from: position, toBoundary: granularity, inDirection: direction) as? IndexedPosition else {
                return
            }
            updateSelection(anchor: ends.anchor, activeLocation: boundary.index, extending: true)
            return
        }
        let referenceIndex = direction == .backward ? currentRange.location : currentRange.upperBound
        let position = IndexedPosition(index: referenceIndex)
        guard let boundary = tokenizer.position(from: position, toBoundary: granularity, inDirection: direction) as? IndexedPosition else {
            return
        }
        updateSelection(anchor: boundary.index, activeLocation: boundary.index, extending: false)
    }

    private func updateSelection(anchor: Int, activeLocation: Int, extending: Bool) {
        selectionAnchor = anchor
        if extending {
            setSelectedRange(from: anchor, to: activeLocation)
            // Host notify deferred via selection mutation paths / setter.
        } else {
            inputDelegate?.selectionWillChange(self)
            selection = NSRange(location: activeLocation, length: 0)
            inputDelegate?.selectionDidChange(self)
        }
    }

    private func moveAllSelectionsByCharacter(in direction: UITextLayoutDirection) {
        moveAllSelections(in: direction)
    }

    private func shouldInsert(characters: String, flags: NSEvent.ModifierFlags) -> Bool {
        if flags.contains(.command) || flags.contains(.control) {
            return false
        }
        if characters == "\t" || characters == "\n" || characters == "\r" {
            return true
        }
        return characters.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func isPointOnSelectionHandle(_ point: CGPoint) -> Bool {
        guard let selection = selection, selection.length > 0 else {
            return false
        }
        for subview in subviews.reversed() {
            guard let handle = subview as? SelectionHandleView, !handle.isHidden else {
                continue
            }
            if handle.frame.insetBy(dx: -4, dy: -4).contains(point) {
                return true
            }
        }
        return false
    }
}
