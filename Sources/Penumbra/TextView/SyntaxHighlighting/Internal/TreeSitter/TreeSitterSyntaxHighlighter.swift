import Foundation
@preconcurrency import AppKit

enum TreeSitterSyntaxHighlighterError: LocalizedError {
    case cancelled
    case operationDeallocated
    case syntaxTreeNotReady

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Operation was cancelled"
        case .operationDeallocated:
            return "The operation was deallocated"
        case .syntaxTreeNotReady:
            return "The syntax tree was being reparsed"
        }
    }
}

final class TreeSitterSyntaxHighlighter: LineSyntaxHighlighter, @unchecked Sendable {
    var theme: Theme = DefaultTheme.placeholder
    var kern: CGFloat = 0
    var canHighlight: Bool {
        languageMode.canHighlight
    }
    var canEventuallyHighlight: Bool {
        languageMode.highlightsQueryAvailable
    }
    var isHighlighting: Bool {
        guard let operation = currentOperation else {
            return false
        }
        return !operation.isFinished && !operation.isCancelled
    }

    /// Host-supplied highlights painted over the tree-sitter colours, when set.
    var semanticHighlights: SemanticHighlightStore?

    private let stringView: StringView
    private let languageMode: TreeSitterInternalLanguageMode
    private let operationQueue: OperationQueue
    private var currentOperation: Operation?
    /// Set by the latest highlight pass. Callers skip a re-typeset when the colours did not change.
    private(set) var lastHighlightChangedAttributes = true
    private(set) var lastSyncHighlightWasComplete = true

    init(stringView: StringView, languageMode: TreeSitterInternalLanguageMode, operationQueue: OperationQueue) {
        self.stringView = stringView
        self.languageMode = languageMode
        self.operationQueue = operationQueue
    }

    func syntaxHighlight(_ input: LineSyntaxHighlighterInput) {
        guard let captures = languageMode.capturesIfReady(in: input.byteRange) else {
            lastSyncHighlightWasComplete = false
            lastHighlightChangedAttributes = false
            return
        }
        lastSyncHighlightWasComplete = true
        apply(captures, to: input)
    }

    private func apply(_ captures: [TreeSitterCapture], to input: LineSyntaxHighlighterInput) {
        let tokens = self.tokens(for: captures, localTo: input.byteRange)
        let colorsChanged = setAttributes(for: tokens, on: input.attributedString)
        let semanticChanged = applySemanticHighlights(to: input)
        lastHighlightChangedAttributes = colorsChanged || semanticChanged
    }

    func syntaxHighlightFromCache(_ input: LineSyntaxHighlighterInput) -> Bool {
        guard let captures = languageMode.cachedCapturesIfReady(in: input.byteRange) else {
            return false
        }
        apply(captures, to: input)
        return true
    }

    func syntaxHighlight(_ input: LineSyntaxHighlighterInput, completion: @escaping AsyncCallback) {
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation, weak self] in
            guard let operation = operation, let self = self else {
                DispatchQueue.main.async {
                    completion(.failure(TreeSitterSyntaxHighlighterError.operationDeallocated))
                }
                return
            }
            guard !operation.isCancelled else {
                DispatchQueue.main.async {
                    completion(.failure(TreeSitterSyntaxHighlighterError.cancelled))
                }
                return
            }
            guard let captures = self.languageMode.capturesIfReady(in: input.byteRange) else {
                // Succeeding here would leave the line in `theme.textColor`, marked highlighted.
                DispatchQueue.main.async {
                    completion(.failure(TreeSitterSyntaxHighlighterError.syntaxTreeNotReady))
                }
                return
            }
            let tokens = self.tokens(for: captures, localTo: input.byteRange)
            if !operation.isCancelled {
                DispatchQueue.main.async {
                    if !operation.isCancelled {
                        let colorsChanged = self.setAttributes(for: tokens, on: input.attributedString)
                        let semanticChanged = self.applySemanticHighlights(to: input)
                        self.lastHighlightChangedAttributes = colorsChanged || semanticChanged
                        completion(.success(()))
                    } else {
                        completion(.failure(TreeSitterSyntaxHighlighterError.cancelled))
                    }
                }
            } else {
                DispatchQueue.main.async {
                    completion(.failure(TreeSitterSyntaxHighlighterError.cancelled))
                }
            }
        }
        currentOperation = operation
        operationQueue.addOperation(operation)
    }

    func cancel() {
        currentOperation?.cancel()
        currentOperation = nil
    }
}

extension TreeSitterSyntaxHighlighter {
    /// The font a token derives its bold/italic variant from. A token with no font of its own inherits
    /// whatever is already applied at its location, so a capture nested in a larger one (`**bold**`
    /// inside a `# heading`) keeps the enclosing size instead of snapping back to the body font.
    /// Captures arrive outermost-first, and default attributes are reapplied before every pass, so
    /// `currentFont` is always the enclosing capture's font, never a stale one.
    static func baseFont(tokenFont: UIFont?, currentFont: UIFont?, defaultFont: UIFont) -> UIFont {
        tokenFont ?? currentFont ?? defaultFont
    }
}

private extension TreeSitterSyntaxHighlighter {
    /// Paints the host's highlights over this line, after the tree-sitter pass. Only the colour is
    /// set (never the font), so line metrics don't change. A name the theme has no colour for
    /// leaves the tree-sitter colour alone.
    @discardableResult
    func applySemanticHighlights(to input: LineSyntaxHighlighterInput) -> Bool {
        guard let store = semanticHighlights, !store.isEmpty else { return false }
        let lineStart = input.byteRange.lowerBound.utf16Length
        let lineRange = NSRange(location: lineStart, length: input.attributedString.length)
        let matches = store.highlights(intersecting: lineRange)
        guard !matches.isEmpty else { return false }
        var changed = false
        input.attributedString.beginEditing()
        for highlight in matches {
            guard let color = theme.textColor(for: highlight.highlightName),
                  let overlap = highlight.range.intersection(lineRange), overlap.length > 0 else { continue }
            let local = NSRange(location: overlap.location - lineStart, length: overlap.length)
            if !Self.attribute(attributedString: input.attributedString, key: .foregroundColor, equals: color, in: local) {
                input.attributedString.addAttribute(.foregroundColor, value: color, range: local)
                changed = true
            }
        }
        input.attributedString.endEditing()
        return changed
    }

    @discardableResult
    private func setAttributes(for tokens: [TreeSitterSyntaxHighlightToken], on attributedString: NSMutableAttributedString) -> Bool {
        attributedString.beginEditing()
        var changed = false
        let defaultFont = theme.font
        for token in coalesce(tokens) {
            if token.fontTraits.isEmpty && token.font == nil {
                if let foregroundColor = token.textColor,
                   !Self.attribute(attributedString: attributedString, key: .foregroundColor, equals: foregroundColor, in: token.range) {
                    attributedString.addAttribute(.foregroundColor, value: foregroundColor, range: token.range)
                    changed = true
                }
                if let shadow = token.shadow,
                   !Self.attribute(attributedString: attributedString, key: .shadow, equals: shadow, in: token.range) {
                    attributedString.addAttribute(.shadow, value: shadow, range: token.range)
                    changed = true
                }
                continue
            }
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let foregroundColor = token.textColor {
                attributes[.foregroundColor] = foregroundColor
            }
            if let shadow = token.shadow {
                attributes[.shadow] = shadow
            }
            if token.fontTraits.contains(.bold) {
                attributedString.addAttribute(.isBold, value: true, range: token.range)
            }
            if token.fontTraits.contains(.italic) {
                attributedString.addAttribute(.isItalic, value: true, range: token.range)
            }
            var symbolicTraits: UIFontDescriptor.SymbolicTraits = []
            if let isBold = attributedString.attribute(.isBold, at: token.range.location, effectiveRange: nil) as? Bool, isBold {
                symbolicTraits.insert(.bold)
            }
            if let isItalic = attributedString.attribute(.isItalic, at: token.range.location, effectiveRange: nil) as? Bool, isItalic {
                symbolicTraits.insert(.italic)
            }
            let currentFont = attributedString.attribute(.font, at: token.range.location, effectiveRange: nil) as? UIFont
            let baseFont = Self.baseFont(tokenFont: token.font, currentFont: currentFont, defaultFont: defaultFont)
            let newFont: UIFont
            if !symbolicTraits.isEmpty {
                newFont = DerivedFontCache.font(baseFont, traits: symbolicTraits)
            } else {
                newFont = baseFont
            }
            if newFont != currentFont {
                attributes[.font] = newFont
            }
            var filtered: [NSAttributedString.Key: Any] = [:]
            for (key, value) in attributes where !Self.attribute(
                attributedString: attributedString, key: key, equals: value, in: token.range
            ) {
                filtered[key] = value
            }
            if !filtered.isEmpty {
                attributedString.addAttributes(filtered, range: token.range)
                changed = true
            }
        }
        attributedString.endEditing()
        return changed
    }

    /// True when every character in `range` already has `value` for `key`.
    private static func attribute(
        attributedString: NSAttributedString,
        key: NSAttributedString.Key,
        equals value: Any,
        in range: NSRange
    ) -> Bool {
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= attributedString.length else {
            return false
        }
        let expected = value as AnyObject
        var location = range.location
        while location < NSMaxRange(range) {
            var effective = NSRange()
            guard let existing = attributedString.attribute(key, at: location, effectiveRange: &effective) else {
                return false
            }
            if !(existing as AnyObject).isEqual(expected) {
                return false
            }
            if effective.upperBound <= location {
                return false
            }
            location = effective.upperBound
        }
        return true
    }

    private func coalesce(_ tokens: [TreeSitterSyntaxHighlightToken]) -> [TreeSitterSyntaxHighlightToken] {
        guard var current = tokens.first else {
            return []
        }
        var result: [TreeSitterSyntaxHighlightToken] = []
        result.reserveCapacity(tokens.count)
        for token in tokens.dropFirst() {
            if current.hasSameStyle(as: token), token.range.location <= current.upperBound {
                current = current.merging(token)
            } else {
                result.append(current)
                current = token
            }
        }
        result.append(current)
        return result
    }

    private func tokens(for captures: [TreeSitterCapture], localTo localRange: ByteRange) -> [TreeSitterSyntaxHighlightToken] {
        var tokens: [TreeSitterSyntaxHighlightToken] = []
        tokens.reserveCapacity(captures.count)
        for capture in captures where capture.byteRange.overlaps(localRange) {
            // We highlight each line separately but a capture may extend beyond a line,
            // e.g. an unterminated string, so we need to cap the start and end location
            // to ensure it's within the line.
            let cappedStartByte = max(capture.byteRange.lowerBound, localRange.lowerBound)
            let cappedEndByte = min(capture.byteRange.upperBound, localRange.upperBound)
            let length = cappedEndByte - cappedStartByte
            let cappedRange = ByteRange(location: cappedStartByte - localRange.lowerBound, length: length)
            if !cappedRange.isEmpty {
                let token = token(from: capture, in: cappedRange)
                if !token.isEmpty {
                    tokens.append(token)
                }
            }
        }
        return tokens
    }
}

private extension TreeSitterSyntaxHighlighter {
    private func token(from capture: TreeSitterCapture, in byteRange: ByteRange) -> TreeSitterSyntaxHighlightToken {
        let range = NSRange(byteRange)
        let textColor = theme.textColor(for: capture.name)
        let shadow = theme.shadow(for: capture.name)
        let font = theme.font(for: capture.name)
        let fontTraits = theme.fontTraits(for: capture.name)
        return TreeSitterSyntaxHighlightToken(range: range, textColor: textColor, shadow: shadow, font: font, fontTraits: fontTraits)
    }
}

private extension UIFont {
    func withSymbolicTraits(_ symbolicTraits: UIFontDescriptor.SymbolicTraits) -> UIFont? {
        let newFontDescriptor = fontDescriptor.withSymbolicTraits(symbolicTraits)
        return NSFont(descriptor: newFontDescriptor, size: pointSize)
    }
}

private enum DerivedFontCache {
    // Keyed by the font itself, not its address: an `ObjectIdentifier` doesn't retain, so a
    // deallocated font's address could be reused by a different one and return the wrong derivation.
    private struct Key: Hashable {
        let base: UIFont
        let traits: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fonts: [Key: UIFont] = [:]

    static func font(_ base: UIFont, traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let key = Key(base: base, traits: Int(traits.rawValue))
        lock.lock()
        if let cached = fonts[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let derived = base.withSymbolicTraits(traits) ?? base
        lock.lock()
        fonts[key] = derived
        lock.unlock()
        return derived
    }
}
