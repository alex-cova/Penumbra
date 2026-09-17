import Foundation

final class StringViewBytesResult {
    // The bytes are not deallocated by this type.
    let bytes: UnsafePointer<Int8>
    let length: ByteCount

    init(bytes: UnsafePointer<Int8>, length: ByteCount) {
        self.bytes = bytes
        self.length = length
    }
}

/// Document text facade. Small / untitled buffers stay a contiguous `NSMutableString`.
/// Large untitled buffers and ``TextViewState/load`` use a ``PieceTree`` (mmap original +
/// append-only add buffer for files; add-buffer-only for untitled).
final class StringView {
    static let pieceTreeUntitledThreshold = 256 * 1024

    private enum Storage {
        case contiguous(NSMutableString)
        case pieceTree(PieceTree)
    }

    private var storage: Storage
    private let lock = NSRecursiveLock()

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Bumped on storage mutation so a save can detect concurrent edits.
    private(set) var contentGeneration: UInt64 = 0

    /// UTF-16 length. Prefer this over ``string``.length so file-backed documents do not materialize.
    var length: Int {
        withLock {
            switch storage {
            case .contiguous(let string):
                return string.length
            case .pieceTree(let tree):
                return tree.utf16Length
            }
        }
    }

    var byteCount: ByteCount {
        ByteCount(utf16Length: length)
    }

    /// True only when the piece tree still holds a file mapping. Untitled piece trees are not file-backed.
    var isFileBacked: Bool {
        withLock {
            if case .pieceTree(let tree) = storage {
                return tree.isFileMapped
            }
            return false
        }
    }

    var usesPieceTree: Bool {
        withLock {
            if case .pieceTree = storage {
                return true
            }
            return false
        }
    }

    /// Full-document `NSString`. Bridging a file-backed buffer allocates UTF-16 of the entire file.
    var string: NSString {
        get {
            withLock {
                switch storage {
                case .contiguous(let string):
                    return string
                case .pieceTree(let tree):
                    return tree.materializeNSString()
                }
            }
        }
        set {
            withLock {
                storage = Self.makeStorage(for: newValue)
                contentGeneration &+= 1
            }
        }
    }

    init(string: NSMutableString = NSMutableString()) {
        self.storage = Self.makeStorage(for: string)
    }

    init(string: String) {
        self.storage = Self.makeStorage(for: string)
    }

    init(pieceTree: PieceTree) {
        self.storage = .pieceTree(pieceTree)
    }

    private static func makeStorage(for string: NSString) -> Storage {
        if string.length >= pieceTreeUntitledThreshold {
            return .pieceTree(PieceTree(string: string as String))
        }
        if let mutable = string as? NSMutableString {
            return .contiguous(mutable)
        }
        return .contiguous(NSMutableString(string: string))
    }

    /// Storage for a Swift `String`, skipping the `NSMutableString` round trip a large document
    /// does not need: the piece tree reads the string's UTF-8 directly.
    ///
    /// The threshold is still measured in UTF-16 units so which documents become piece trees does
    /// not change. `utf16.count` walks the string but allocates nothing, unlike the
    /// `NSMutableString` copy it replaces.
    private static func makeStorage(for string: String) -> Storage {
        if string.utf16.count >= pieceTreeUntitledThreshold {
            return .pieceTree(PieceTree(string: string))
        }
        return .contiguous(NSMutableString(string: string))
    }

    func substring(in range: NSRange) -> String? {
        withLock {
            switch storage {
            case .contiguous(let string):
                guard range.location >= 0, range.upperBound <= string.length else {
                    return nil
                }
                if range.length == 0 {
                    return ""
                }
                return string.substring(with: range)
            case .pieceTree(let tree):
                return tree.substring(in: range)
            }
        }
    }

    func character(at location: Int) -> Character? {
        withLock {
            switch storage {
            case .contiguous(let string):
                if location >= 0 && location < string.length, let scalar = Unicode.Scalar(string.character(at: location)) {
                    return Character(scalar)
                }
                return nil
            case .pieceTree(let tree):
                return tree.character(at: location)
            }
        }
    }

    func replaceText(in range: NSRange, with string: String) {
        PenumbraSignposts.interval("StringView.replaceText") {
            withLock {
                switch storage {
                case .contiguous(let mutable):
                    mutable.replaceCharacters(in: range, with: string)
                case .pieceTree(let tree):
                    tree.replaceText(in: range, with: string)
                }
                contentGeneration &+= 1
            }
        }
    }

    func bytes(in range: ByteRange) -> StringViewBytesResult? {
        withLock {
            switch storage {
            case .contiguous:
                guard range.lowerBound.value >= 0 && range.upperBound <= byteCount else {
                    return nil
                }
                let stringRange = NSRange(range)
                var usedLength = 0
                if let buffer = string.getBytes(in: stringRange, encoding: String.preferredUTF16Encoding, usedLength: &usedLength) {
                    return StringViewBytesResult(bytes: buffer, length: ByteCount(usedLength))
                }
                return nil
            case .pieceTree(let tree):
                return tree.bytes(in: range)
            }
        }
    }

    /// Per-line UTF-16 lengths for the whole document, or `nil` when the caller should fall back to
    /// walking newlines itself.
    ///
    /// Only piece-tree storage answers this. A contiguous `NSMutableString` is already served well
    /// by `NSString.getLineStart` (``NewLineFinder``), which is a single bounded call per line; a
    /// piece tree is not, because each UTF-16 unit read costs an allocation plus a byte walk from
    /// the nearest checkpoint.
    func lineMetrics() -> [LineMetric]? {
        withLock {
            switch storage {
            case .contiguous:
                return nil
            case .pieceTree(let tree):
                return tree.lineMetrics()
            }
        }
    }

    func rangeOfNextNewLine(startingAt location: Int) -> NSRange? {
        withLock {
            switch storage {
            case .contiguous(let string):
                return NewLineFinder.rangeOfNextNewLine(in: string, startingAt: location)
            case .pieceTree(let tree):
                return tree.rangeOfNextNewLine(startingAt: location)
            }
        }
    }

    func paragraphStart(before location: Int) -> Int {
        withLock {
            switch storage {
            case .contiguous(let string):
                return NewLineFinder.startOfParagraph(before: location, in: string)
            case .pieceTree(let tree):
                return tree.paragraphStart(before: location)
            }
        }
    }

    func rangeOfCharacter(from set: CharacterSet, options: NSString.CompareOptions = [], range: NSRange) -> NSRange {
        withLock {
            switch storage {
            case .contiguous(let string):
                return string.rangeOfCharacter(from: set, options: options, range: range)
            case .pieceTree(let tree):
                return tree.rangeOfCharacter(from: set, options: options, range: range)
            }
        }
    }

    func rangeOfComposedCharacterSequence(at location: Int) -> NSRange {
        switch storage {
        case .contiguous(let string):
            return string.customRangeOfComposedCharacterSequence(at: location)
        case .pieceTree(let tree):
            return tree.rangeOfComposedCharacterSequence(at: location)
        }
    }

    func rangeOfComposedCharacterSequences(for range: NSRange) -> NSRange {
        switch storage {
        case .contiguous(let string):
            return string.customRangeOfComposedCharacterSequences(for: range)
        case .pieceTree:
            guard range.length > 0 else {
                return rangeOfComposedCharacterSequence(at: range.location)
            }
            let start = rangeOfComposedCharacterSequence(at: range.location)
            let last = max(range.location, range.upperBound - 1)
            let end = rangeOfComposedCharacterSequence(at: last)
            let location = min(start.location, end.location)
            return NSRange(location: location, length: NSMaxRange(end) - location)
        }
    }

    func enumerateSubstrings(
        in range: NSRange,
        options: NSString.EnumerationOptions,
        using block: @escaping (String?, NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        switch storage {
        case .contiguous(let string):
            string.enumerateSubstrings(in: range, options: options, using: block)
        case .pieceTree(let tree):
            tree.enumerateSubstrings(in: range, options: options, using: block)
        }
    }

    func prefetch(utf16Range: NSRange) {
        if case .pieceTree(let tree) = storage {
            tree.prefetch(utf16Range: utf16Range)
        }
    }

    func contentSnapshot() -> PieceTreeContentSnapshot? {
        if case .pieceTree(let tree) = storage {
            return tree.contentSnapshot()
        }
        return nil
    }

    func compactPieceTree(mapping: FileMapping, footer: DocumentWriteFooter) {
        if case .pieceTree(let tree) = storage {
            tree.compact(mapping: mapping, footer: footer)
        }
    }

    var materializeCount: Int {
        if case .pieceTree(let tree) = storage {
            return tree.materializeCount
        }
        return 0
    }

    var pieceCount: Int {
        if case .pieceTree(let tree) = storage {
            return tree.pieceCount
        }
        return 1
    }

    var addBufferByteCount: Int {
        if case .pieceTree(let tree) = storage {
            return tree.addBufferByteCount
        }
        return 0
    }

    var lastPrefetchByteCount: Int {
        if case .pieceTree(let tree) = storage {
            return tree.lastPrefetchByteCount
        }
        return 0
    }

    func unichar(at location: Int) -> unichar? {
        withLock {
            switch storage {
            case .contiguous(let string):
                guard location >= 0, location < string.length else {
                    return nil
                }
                return string.character(at: location)
            case .pieceTree(let tree):
                return tree.unichar(at: location)
            }
        }
    }
}
