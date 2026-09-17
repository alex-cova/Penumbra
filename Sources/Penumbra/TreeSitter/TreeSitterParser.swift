import Foundation
import TreeSitter

protocol TreeSitterParserDelegate: AnyObject {
    func parser(_ parser: TreeSitterParser, bytesAt byteIndex: ByteCount) -> TreeSitterTextProviderResult?
}

final class TreeSitterParser {
    weak var delegate: TreeSitterParserDelegate?
    let encoding: TSInputEncoding
    /// Cooperative cancellation checked from tree-sitter's parse progress callback.
    /// Returning `true` from the callback aborts `ts_parser_parse`; callers must then ``reset()``
    /// so the next parse does not resume the cancelled one.
    var shouldCancel: (() -> Bool)?
    /// True when the most recent ``parse`` returned `nil` because the progress callback aborted.
    private(set) var lastParseAborted = false
    var language: TreeSitterLanguagePointer? {
        didSet {
            ts_parser_set_language(pointer, language)
        }
    }
    var canParse: Bool {
        language != nil
    }

    private var pointer: OpaquePointer

    init(encoding: TSInputEncoding) {
        self.encoding = encoding
        self.pointer = ts_parser_new()
    }

    deinit {
        ts_parser_delete(pointer)
    }

    func reset() {
        ts_parser_reset(pointer)
    }

    func parse(_ string: NSString, oldTree: TreeSitterTree? = nil) -> TreeSitterTree? {
        PenumbraSignposts.interval("TreeSitterParser.parse") {
            guard string.length > 0 else {
                lastParseAborted = false
                return nil
            }
            guard let stringEncoding = encoding.stringEncoding else {
                lastParseAborted = false
                return nil
            }
            var usedLength = 0
            let buffer = string.getAllBytes(withEncoding: stringEncoding, usedLength: &usedLength)
            defer { buffer?.deallocate() }
            guard let buffer else {
                lastParseAborted = false
                return nil
            }
            let newTreePointer = parseWithCancellation(
                buffer: buffer,
                length: UInt32(usedLength),
                oldTree: oldTree
            )
            if let newTreePointer = newTreePointer {
                return TreeSitterTree(newTreePointer)
            } else {
                return nil
            }
        }
    }

    func parse(oldTree: TreeSitterTree? = nil) -> TreeSitterTree? {
        PenumbraSignposts.interval("TreeSitterParser.parse") {
            let input = TreeSitterTextInput(encoding: encoding) { [weak self] byteIndex, _ in
                if let self = self {
                    return self.delegate?.parser(self, bytesAt: byteIndex)
                } else {
                    return nil
                }
            }
            let newTreePointer = parseWithCancellation(input: input.makeTSInput(), oldTree: oldTree)
            input.deallocate()
            if let newTreePointer = newTreePointer {
                return TreeSitterTree(newTreePointer)
            } else {
                return nil
            }
        }
    }

    private func parseWithCancellation(
        buffer: UnsafePointer<Int8>,
        length: UInt32,
        oldTree: TreeSitterTree?
    ) -> OpaquePointer? {
        let payload = ContiguousParseInput(buffer: buffer, length: length)
        let input = TSInput(
            payload: Unmanaged.passUnretained(payload).toOpaque(),
            read: contiguousParseRead,
            encoding: encoding,
            decode: nil
        )
        return parseWithCancellation(input: input, oldTree: oldTree)
    }

    private func parseWithCancellation(input: TSInput, oldTree: TreeSitterTree?) -> OpaquePointer? {
        lastParseAborted = false
        let box = ParseCancelBox(
            shouldCancel: shouldCancel ?? { false },
            enforceMainThreadTimeout: Thread.isMainThread
        )
        var options = TSParseOptions()
        options.payload = Unmanaged.passUnretained(box).toOpaque()
        options.progress_callback = parseProgressCallback
        let tree = ts_parser_parse_with_options(pointer, oldTree?.pointer, input, options)
        box.finish()
        if tree == nil {
            lastParseAborted = box.didAbort
            ts_parser_reset(pointer)
        }
        return tree
    }

    @discardableResult
    func setIncludedRanges(_ ranges: [TreeSitterTextRange]) -> Bool {
        let rawRanges = ranges.map { $0.rawValue }
        return rawRanges.withUnsafeBufferPointer { rangesPointer in
            ts_parser_set_included_ranges(pointer, rangesPointer.baseAddress, UInt32(rawRanges.count))
        }
    }

    func removeAllIncludedRanges() {
        ts_parser_set_included_ranges(pointer, nil, 0)
    }
}

/// Holds the cancel predicate for the duration of a `ts_parser_parse_with_options` call.
private final class ParseCancelBox {
    let shouldCancel: () -> Bool
    let enforceMainThreadTimeout: Bool
    let start: CFAbsoluteTime
    var didPostLongParse = false
    var didAbort = false

    init(shouldCancel: @escaping () -> Bool, enforceMainThreadTimeout: Bool) {
        self.shouldCancel = shouldCancel
        self.enforceMainThreadTimeout = enforceMainThreadTimeout
        self.start = CFAbsoluteTimeGetCurrent()
    }

    func check() -> Bool {
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        if !didPostLongParse, elapsed >= TreeSitterPerformanceConstants.longParseTimeout {
            didPostLongParse = true
            NotificationCenter.default.post(
                name: TreeSitterPerformanceConstants.longParseNotification,
                object: nil
            )
        }
        if enforceMainThreadTimeout, elapsed >= TreeSitterPerformanceConstants.parserTimeout {
            didAbort = true
            return true
        }
        if shouldCancel() {
            didAbort = true
            return true
        }
        return false
    }

    func finish() {
        if didPostLongParse {
            NotificationCenter.default.post(
                name: TreeSitterPerformanceConstants.longParseFinishedNotification,
                object: nil
            )
        } else if CFAbsoluteTimeGetCurrent() - start >= TreeSitterPerformanceConstants.longParseTimeout {
            NotificationCenter.default.post(
                name: TreeSitterPerformanceConstants.longParseNotification,
                object: nil
            )
            NotificationCenter.default.post(
                name: TreeSitterPerformanceConstants.longParseFinishedNotification,
                object: nil
            )
        }
    }
}

/// Contiguous-buffer `TSInput` payload matching tree-sitter's internal `TSStringInput`.
private final class ContiguousParseInput {
    let buffer: UnsafePointer<Int8>
    let length: UInt32
    init(buffer: UnsafePointer<Int8>, length: UInt32) {
        self.buffer = buffer
        self.length = length
    }
}

private func parseProgressCallback(state: UnsafeMutablePointer<TSParseState>?) -> Bool {
    guard let payload = state?.pointee.payload else {
        return false
    }
    let box: ParseCancelBox = Unmanaged.fromOpaque(payload).takeUnretainedValue()
    return box.check()
}

private func contiguousParseRead(
    payload: UnsafeMutableRawPointer?,
    byteIndex: UInt32,
    position: TSPoint,
    bytesRead: UnsafeMutablePointer<UInt32>?
) -> UnsafePointer<Int8>? {
    guard let payload else {
        bytesRead?.pointee = 0
        return nil
    }
    let input: ContiguousParseInput = Unmanaged.fromOpaque(payload).takeUnretainedValue()
    if byteIndex >= input.length {
        bytesRead?.pointee = 0
        return nil
    }
    bytesRead?.pointee = input.length - byteIndex
    return input.buffer + Int(byteIndex)
}

private extension TSInputEncoding {
    var stringEncoding: String.Encoding? {
        switch self {
        case TSInputEncodingUTF8:
            return .utf8
        case TSInputEncodingUTF16LE, TSInputEncodingUTF16BE:
            return String.preferredUTF16Encoding
        default:
            return nil
        }
    }
}
