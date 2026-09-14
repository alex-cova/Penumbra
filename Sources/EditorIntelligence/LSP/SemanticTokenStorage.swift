import Foundation

/// Stores semantic token data and supports delta updates from language servers.
public final class SemanticTokenStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var resultId: String?
    private var compressedData: [UInt32] = []
    private var tokens: [LSPSemanticToken] = []

    public init() {}

    public var lastResultId: String? {
        lock.withLock { resultId }
    }

    public var hasReceivedData: Bool {
        lock.withLock { !tokens.isEmpty }
    }

    public func setData(_ semanticTokens: LSPSemanticTokens) {
        lock.withLock {
            resultId = semanticTokens.resultId
            compressedData = semanticTokens.data
            tokens = LSPSemanticTokenDecoder.decode(semanticTokens.data)
        }
    }

    @discardableResult
    public func applyDelta(_ delta: LSPSemanticTokensDelta) -> [LSPSemanticToken] {
        lock.withLock {
            resultId = delta.resultId
            if !delta.edits.isEmpty {
                var buffer = compressedData
                for edit in delta.edits.sorted(by: { $0.start > $1.start }) {
                    let start = min(max(edit.start, 0), buffer.count)
                    let end = min(start + max(edit.deleteCount, 0), buffer.count)
                    buffer.replaceSubrange(start..<end, with: edit.data)
                }
                compressedData = buffer
                tokens = LSPSemanticTokenDecoder.decode(compressedData)
            } else if !delta.data.isEmpty {
                compressedData = delta.data
                tokens = LSPSemanticTokenDecoder.decode(compressedData)
            }
            return tokens
        }
    }

    public func tokens(in range: LSPRange) -> [LSPSemanticToken] {
        lock.withLock {
            tokens.filter { token in
                let start = LSPPosition(line: token.line, character: token.character)
                return start.line < range.end.line
                    || (start.line == range.end.line && start.character < range.end.character)
            }.filter { token in
                let start = LSPPosition(line: token.line, character: token.character)
                return start.line > range.start.line
                    || (start.line == range.start.line && start.character >= range.start.character)
            }
        }
    }

    public func allTokens() -> [LSPSemanticToken] {
        lock.withLock { tokens }
    }
}
