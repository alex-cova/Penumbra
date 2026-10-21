import Foundation

/// Move Caret to Code Block Start / End (⌥⌘[ / ⌥⌘] in the IntelliJ keymap): the braces of the
/// innermost `{ ... }` block around the caret, read from the syntax tree, so braces in strings
/// and comments never count. Pressed again, the caret moves out to the next block.
enum CodeBlockNavigator {
    /// - Parameters:
    ///   - caret: UTF-16 location of the caret.
    ///   - toEnd: the location just after the closing brace when true, else the opening brace.
    ///   - node: the smallest syntax node at the caret.
    /// - Returns: the first block, innermost out, that lies beyond the caret in that direction: a
    ///   caret already standing on a block's brace leaves it for the block around it.
    static func target(from caret: Int, toEnd: Bool, startingAt node: TreeSitterNode) -> Int? {
        var current: TreeSitterNode? = node
        var steps = 0
        while let candidate = current, steps < 512 {
            steps += 1
            if let braces = braces(of: candidate) {
                if toEnd, braces.afterClose > caret { return braces.afterClose }
                if !toEnd, braces.open < caret { return braces.open }
            }
            current = candidate.parent
        }
        return nil
    }

    /// The opening brace and the position after the closing one, for a node written `{ ... }`.
    static func braces(of node: TreeSitterNode) -> (open: Int, afterClose: Int)? {
        let count = node.childCount
        guard count >= 2, let first = node.child(at: 0), let last = node.child(at: count - 1),
              first.type == "{", last.type == "}" else { return nil }
        let open = first.byteRange.location.utf16Length
        let closeStart = last.byteRange.location.utf16Length
        return (open, closeStart + last.byteRange.length.utf16Length)
    }
}

extension TextInputView {
    /// Moves the caret to the start or end of the code block around it; with `extendingSelection`
    /// the other end stays where the selection started.
    @discardableResult
    func moveToCodeBlock(end: Bool, extendingSelection: Bool) -> Bool {
        guard let mode = languageMode as? TreeSitterInternalLanguageMode, let current = selection else { return false }
        // The edge the move starts from: a selection grows from the side it already extends to.
        let caret = end ? current.upperBound : current.location
        guard let position = lineManager.linePosition(at: min(caret, max(stringView.length - 1, 0))),
              let node = mode.treeSitterNode(at: position),
              let target = CodeBlockNavigator.target(from: caret, toEnd: end, startingAt: node) else {
            return false
        }
        if extendingSelection {
            let anchor = end ? current.location : current.upperBound
            selection = NSRange(location: min(anchor, target), length: abs(target - anchor))
        } else {
            selection = NSRange(location: target, length: 0)
        }
        return true
    }
}
