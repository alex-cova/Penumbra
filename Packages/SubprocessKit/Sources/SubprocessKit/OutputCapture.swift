import Foundation

/// How much of a stream to keep.
public enum OutputCapture: Sendable, Equatable {
    /// Everything (git output the caller parses).
    case all
    /// The first `head` bytes and the last `tail` bytes; the middle is dropped and counted. A
    /// build's verdict is at the bottom, so the tail usually gets the larger share.
    case bounded(head: Int, tail: Int)
    /// Nothing is kept (the bytes are still read, and still reach the live callback).
    case discard
}

/// What was kept of one stream.
public struct CapturedOutput: Sendable, Equatable {
    public var head: Data
    public var tail: Data
    /// Bytes dropped between `head` and `tail`.
    public var omittedBytes: Int

    public init(head: Data = Data(), tail: Data = Data(), omittedBytes: Int = 0) {
        self.head = head
        self.tail = tail
        self.omittedBytes = omittedBytes
    }

    public static let empty = CapturedOutput()

    /// `head` then `tail`, with no marker where the middle was dropped.
    public var data: Data { head + tail }

    public var isEmpty: Bool { head.isEmpty && tail.isEmpty }

    /// The kept text; when the middle was dropped, a marker line says how much.
    public var text: String {
        let head = String(decoding: head, as: UTF8.self)
        guard omittedBytes > 0 else { return head + String(decoding: tail, as: UTF8.self) }
        return head + "\n[… \(omittedBytes) bytes omitted …]\n" + String(decoding: tail, as: UTF8.self)
    }
}

/// Accumulates a stream under an `OutputCapture` policy.
struct OutputBuffer {
    let capture: OutputCapture
    private(set) var head = Data()
    private(set) var tail = Data()
    private(set) var omitted = 0

    init(_ capture: OutputCapture) {
        self.capture = capture
    }

    mutating func append(_ data: Data) {
        switch capture {
        case .all:
            head.append(data)
        case .discard:
            omitted += data.count
        case .bounded(let headLimit, let tailLimit):
            var rest = data[...]
            if head.count < headLimit {
                let room = headLimit - head.count
                head.append(rest.prefix(room))
                rest = rest.dropFirst(room)
            }
            guard !rest.isEmpty else { return }
            tail.append(rest)
            if tail.count > tailLimit {
                let drop = tail.count - tailLimit
                tail = Data(tail.suffix(tailLimit))
                omitted += drop
            }
        }
    }

    var captured: CapturedOutput {
        CapturedOutput(head: head, tail: tail, omittedBytes: omitted)
    }
}
