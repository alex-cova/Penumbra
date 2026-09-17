@preconcurrency import AppKit
import Foundation

extension TextInputView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        applyReplacementRange(replacementRange)
        insertText(Self.text(from: string))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        applyReplacementRange(replacementRange)
        setMarkedText(Self.text(from: string), selectedRange: selectedRange)
    }

    func selectedRange() -> NSRange {
        if let selection = selection {
            return selection
        } else {
            return NSRange(location: 0, length: 0)
        }
    }

    func markedRange() -> NSRange {
        if let imeMarkedRange = imeMarkedRange {
            return imeMarkedRange
        } else {
            return NSRange(location: NSNotFound, length: 0)
        }
    }

    func hasMarkedText() -> Bool {
        imeMarkedRange != nil
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange actualRangePtr: NSRangePointer?) -> NSAttributedString? {
        guard let substring = stringView.substring(in: range) else {
            return nil
        }
        actualRangePtr?.pointee = range
        return NSAttributedString(string: substring)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange actualRangePtr: NSRangePointer?) -> NSRect {
        actualRangePtr?.pointee = range
        var rect = caretRect(at: range.location)
        if rect.width == 0 {
            rect.size.width = 1
        }
        guard let window = window else {
            return rect
        }
        let windowRect = convert(rect, to: nil)
        return window.convertToScreen(windowRect)
    }

    func characterIndex(for point: NSPoint) -> Int {
        let localPoint = convert(point, from: nil)
        return characterIndex(at: localPoint) ?? 0
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == .string || returnType == .string {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
}

private extension TextInputView {
    private static func text(from value: Any) -> String {
        if let string = value as? String {
            return string
        } else if let attributedString = value as? NSAttributedString {
            return attributedString.string
        } else if let attributedString = value as? NSMutableAttributedString {
            return attributedString.string
        } else {
            return "\(value)"
        }
    }

    private func applyReplacementRange(_ replacementRange: NSRange) {
        guard replacementRange.location != NSNotFound else {
            return
        }
        selection = replacementRange
    }
}
