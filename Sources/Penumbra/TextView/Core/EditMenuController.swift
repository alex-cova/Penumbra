import Foundation
@preconcurrency import AppKit

@MainActor
protocol EditMenuControllerDelegate: AnyObject {
    func editMenuController(_ controller: EditMenuController, highlightedRangeFor range: NSRange) -> HighlightedRange?
    func editMenuController(_ controller: EditMenuController, canReplaceTextIn highlightedRange: HighlightedRange) -> Bool
    func editMenuController(_ controller: EditMenuController, caretRectAt location: Int) -> CGRect
    func editMenuControllerShouldReplaceText(_ controller: EditMenuController)
    func selectedRange(for controller: EditMenuController) -> NSRange?
    func editMenuControllerIsEditable(_ controller: EditMenuController) -> Bool
}

@MainActor
final class EditMenuController: NSObject {
    weak var delegate: EditMenuControllerDelegate?

    func contextMenu(for textInputView: TextInputView) -> NSMenu {
        let menu = NSMenu()
        let isEditable = delegate?.editMenuControllerIsEditable(self) ?? true
        let hasSelection = (delegate?.selectedRange(for: self)?.length ?? 0) > 0
        let pasteboardHasString = NSPasteboard.general.string(forType: .string) != nil

        let cutItem = NSMenuItem(title: "Cut", action: #selector(TextInputView.cut(_:)), keyEquivalent: "x")
        cutItem.target = textInputView
        cutItem.isEnabled = isEditable && hasSelection
        menu.addItem(cutItem)

        let copyItem = NSMenuItem(title: "Copy", action: #selector(TextInputView.copy(_:)), keyEquivalent: "c")
        copyItem.target = textInputView
        copyItem.isEnabled = hasSelection
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(TextInputView.paste(_:)), keyEquivalent: "v")
        pasteItem.target = textInputView
        pasteItem.isEnabled = isEditable && pasteboardHasString
        menu.addItem(pasteItem)

        menu.addItem(.separator())

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(TextInputView.selectAll(_:)), keyEquivalent: "a")
        selectAllItem.target = textInputView
        menu.addItem(selectAllItem)

        if let replaceItem = replaceMenuItemIfAvailable(for: textInputView) {
            menu.addItem(.separator())
            menu.addItem(replaceItem)
        }

        return menu
    }

    func presentContextMenu(for textInputView: TextInputView, with event: NSEvent) {
        let menu = contextMenu(for: textInputView)
        NSMenu.popUpContextMenu(menu, with: event, for: textInputView)
    }

    func presentEditMenu(from textInputView: TextInputView, forTextIn range: NSRange) {
        let menu = contextMenu(for: textInputView)
        let caretRect = caretRect(at: range.location)
        let point = NSPoint(x: caretRect.midX, y: caretRect.minY)
        menu.popUp(positioning: nil, at: point, in: textInputView)
    }
}

private extension EditMenuController {
    private func highlightedRange(for range: NSRange) -> HighlightedRange? {
        delegate?.editMenuController(self, highlightedRangeFor: range)
    }

    private func canReplaceText(in highlightedRange: HighlightedRange) -> Bool {
        delegate?.editMenuController(self, canReplaceTextIn: highlightedRange) ?? false
    }

    private func caretRect(at location: Int) -> CGRect {
        delegate?.editMenuController(self, caretRectAt: location) ?? .zero
    }

    private func replaceMenuItemIfAvailable(for textInputView: TextInputView) -> NSMenuItem? {
        guard let selectedRange = delegate?.selectedRange(for: self),
              let highlightedRange = highlightedRange(for: selectedRange),
              canReplaceText(in: highlightedRange) else {
            return nil
        }
        let item = NSMenuItem(title: L10n.Menu.ItemTitle.replace, action: #selector(TextInputView.replaceTextInSelectedHighlightedRange), keyEquivalent: "")
        item.target = textInputView
        return item
    }
}
