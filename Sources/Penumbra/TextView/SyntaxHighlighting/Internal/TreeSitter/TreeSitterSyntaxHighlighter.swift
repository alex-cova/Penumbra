import Foundation
@preconcurrency import AppKit

enum TreeSitterSyntaxHighlighterError: LocalizedError {
    case cancelled
    case operationDeallocated

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Operation was cancelled"
        case .operationDeallocated:
            return "The operation was deallocated"
        }
    }
}

final class TreeSitterSyntaxHighlighter: LineSyntaxHighlighter, @unchecked Sendable {
    var theme: Theme = DefaultTheme()
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

    private let stringView: StringView
    private let languageMode: TreeSitterInternalLanguageMode
    private let operationQueue: OperationQueue
    private var currentOperation: Operation?

    init(stringView: StringView, languageMode: TreeSitterInternalLanguageMode, operationQueue: OperationQueue) {
        self.stringView = stringView
        self.languageMode = languageMode
        self.operationQueue = operationQueue
    }

    func syntaxHighlight(_ input: LineSyntaxHighlighterInput) {
        let captures = languageMode.captures(in: input.byteRange)
        let tokens = self.tokens(for: captures, localTo: input.byteRange)
        setAttributes(for: tokens, on: input.attributedString)
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
            let captures = self.languageMode.captures(in: input.byteRange)
            let tokens = self.tokens(for: captures, localTo: input.byteRange)
            if !operation.isCancelled {
                DispatchQueue.main.async {
                    if !operation.isCancelled {
                        self.setAttributes(for: tokens, on: input.attributedString)
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

private extension TreeSitterSyntaxHighlighter {
    private func setAttributes(for tokens: [TreeSitterSyntaxHighlightToken], on attributedString: NSMutableAttributedString) {
        attributedString.beginEditing()
        let defaultFont = theme.font
        for token in coalesce(tokens) {
            if token.fontTraits.isEmpty && token.font == nil {
                if let foregroundColor = token.textColor {
                    attributedString.addAttribute(.foregroundColor, value: foregroundColor, range: token.range)
                }
                if let shadow = token.shadow {
                    attributedString.addAttribute(.shadow, value: shadow, range: token.range)
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
            let baseFont = token.font ?? defaultFont
            let newFont: UIFont
            if !symbolicTraits.isEmpty {
                newFont = DerivedFontCache.font(baseFont, traits: symbolicTraits)
            } else {
                newFont = baseFont
            }
            if newFont != currentFont {
                attributes[.font] = newFont
            }
            if !attributes.isEmpty {
                attributedString.addAttributes(attributes, range: token.range)
            }
        }
        attributedString.endEditing()
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
    private struct Key: Hashable {
        let fontID: ObjectIdentifier
        let traits: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fonts: [Key: UIFont] = [:]

    static func font(_ base: UIFont, traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let key = Key(fontID: ObjectIdentifier(base), traits: Int(traits.rawValue))
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
