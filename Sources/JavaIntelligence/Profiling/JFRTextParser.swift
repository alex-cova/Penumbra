import Foundation

/// The frames of every stack in a profile, interned: a method and a line, each stored once. A
/// recording repeats the same few thousand frames millions of times, so everything downstream
/// holds `Int32` ids and a stack is an array of them.
///
/// Not thread-safe: one import owns it and hands it over, finished, with the profile.
public final class JavaProfileSymbols: @unchecked Sendable {
    public struct Method: Hashable, Sendable {
        /// `com.example.Order$Line`, `app.Spin$$Lambda/0x0000000800c03000`; empty for a frame with
        /// no class (a native frame the tool printed without one).
        public var className: String
        /// `total`, `<init>`, `lambda$main$0`.
        public var name: String
        /// The parameter list as printed, `int, String`.
        public var parameters: String
    }

    public struct Frame: Hashable, Sendable {
        public var method: Int32
        /// 1-based; 0 when the recorder had none (native, hidden or a negative line).
        public var line: Int32
    }

    public private(set) var methods: [Method] = []
    public private(set) var frames: [Frame] = []
    private var methodIDs: [Method: Int32] = [:]
    private var frameIDs: [Frame: Int32] = [:]
    /// The source file Instruments recorded for a method, by method id. JFR frames carry no
    /// file path, so this stays empty for them and `Method` identity is unchanged.
    private var methodSourcePaths: [Int32: String] = [:]

    public init() {}

    public func internMethod(className: String, name: String, parameters: String) -> Int32 {
        let method = Method(className: className, name: name, parameters: parameters)
        if let id = methodIDs[method] { return id }
        let id = Int32(methods.count)
        methods.append(method)
        methodIDs[method] = id
        return id
    }

    public func internFrame(method: Int32, line: Int32) -> Int32 {
        let frame = Frame(method: method, line: max(0, line))
        if let id = frameIDs[frame] { return id }
        let id = Int32(frames.count)
        frames.append(frame)
        frameIDs[frame] = id
        return id
    }

    public func method(ofFrame id: Int32) -> Method { methods[Int(frames[Int(id)].method)] }
    public func frame(_ id: Int32) -> Frame { frames[Int(id)] }

    /// Records the source file a method was recorded in. The first path wins: one method
    /// inlines in one file, and a later conflicting record would only hide the earlier one.
    public func setSourcePath(_ path: String, forMethod id: Int32) {
        guard !path.isEmpty, methodSourcePaths[id] == nil else { return }
        methodSourcePaths[id] = path
    }

    /// The recorded source file of a method, if any.
    public func sourcePath(ofMethod id: Int32) -> String? { methodSourcePaths[id] }

    /// The recorded source file of a frame's method, if any.
    public func sourcePath(ofFrame id: Int32) -> String? {
        guard id >= 0, Int(id) < frames.count else { return nil }
        return methodSourcePaths[frames[Int(id)].method]
    }

    /// `Order$Line.total(int, String)`: the class's simple name, for the tables.
    public func displayName(ofMethod id: Int32) -> String {
        let method = methods[Int(id)]
        let simple = method.className.split(separator: ".").last.map(String.init) ?? method.className
        let owner = simple.isEmpty ? "" : simple + "."
        return owner + method.name
    }

    /// `com.example.Order$Line.total` including the package.
    public func qualifiedName(ofMethod id: Int32) -> String {
        let method = methods[Int(id)]
        return method.className.isEmpty ? method.name : method.className + "." + method.name
    }

    /// The package of a method's class, for colouring: `com.example` of `com.example.Order$Line`.
    public func packageName(ofMethod id: Int32) -> String {
        let className = methods[Int(id)].className
        guard let dot = className.lastIndex(of: ".") else { return "" }
        return String(className[..<dot])
    }
}

/// One event of `jfr print`, with its stack as interned frame ids (leaf first, as printed).
public struct JFRTextEvent: Sendable {
    public var type: String
    public var thread: String?
    public var threadID: Int?
    /// Leaf first; at most the stack depth the tool was asked for.
    public var frames: [Int32]
    /// The stack ended in `...`: the recorder or `--stack-depth` cut it off.
    public var isTruncated: Bool
    /// The captured `key = value` lines (``JFRTextParser/capturedKeys``), values as printed.
    public var attributes: [String: String]
    /// `startTime` in milliseconds on the printer's wall clock (local time and date as printed, so
    /// only differences mean anything); `nil` when the event has none or it did not parse.
    public var timeMillis: Int64?

    public init(
        type: String, thread: String? = nil, threadID: Int? = nil, frames: [Int32] = [],
        isTruncated: Bool = false, attributes: [String: String] = [:], timeMillis: Int64? = nil
    ) {
        self.type = type
        self.thread = thread
        self.threadID = threadID
        self.frames = frames
        self.isTruncated = isTruncated
        self.attributes = attributes
        self.timeMillis = timeMillis
    }

    /// A percentage such as `37.5%` as a fraction (`0.375`); a bare number is taken as one already.
    public func fraction(_ key: String) -> Double? {
        guard let text = attributes[key] else { return nil }
        return JFRTextParser.parseFraction(text)
    }

    /// A size such as `142.9 kB` or `1.5 MB`, in bytes.
    public func bytes(_ key: String) -> Int? {
        guard let text = attributes[key] else { return nil }
        return JFRTextParser.parseBytes(text)
    }

    /// A duration such as `0.841 ms` or `2.3 s`, in nanoseconds.
    public func nanoseconds(_ key: String) -> Int? {
        guard let text = attributes[key] else { return nil }
        return JFRTextParser.parseNanoseconds(text)
    }
}

/// Reads the default text form of `jfr print` as a stream, one event at a time, so neither the
/// output nor the events are ever held whole.
///
/// ```
/// jdk.ExecutionSample {
///   startTime = 12:51:14.809 (2026-10-13)
///   sampledThread = "main" (javaThreadId = 3)
///   stackTrace = [
///     app.Spin.fib(int) line: 5
///     ...
///   ]
/// }
/// ```
///
/// Feed it bytes as they arrive (`feed(_:emit:)`, any chunking) and call `finish(emit:)` at the end.
public struct JFRTextParser {
    /// The `key = value` lines kept on an event; every other line is skipped unread.
    public static let capturedKeys: Set<String> = [
        "sampledThread", "eventThread", "thread", "objectClass", "weight", "duration", "name", "cause",
        "sumOfPauses", "longestPause", "state", "monitorClass", "parkedClass", "startTime", "gcId",
        "machineTotal", "jvmUser", "jvmSystem", "heapUsed", "when", "host", "port", "path",
        "bytesRead", "bytesWritten"
    ]

    public let symbols: JavaProfileSymbols
    /// Event types to emit; `nil` emits all. An unwanted event is still read through, since its
    /// braces have to be matched.
    public var wantedEvents: Set<String>?

    /// How many lines were read, for progress.
    public private(set) var linesRead = 0

    private var pending: [UInt8] = []
    private var frameCache: [String: Int32] = [:]
    private static let frameCacheLimit = 400_000

    private var eventType: String?
    private var depth = 0
    private var inStack = false
    private var frames: [Int32] = []
    private var truncated = false
    private var attributes: [String: String] = [:]

    public init(symbols: JavaProfileSymbols = JavaProfileSymbols(), wantedEvents: Set<String>? = nil) {
        self.symbols = symbols
        self.wantedEvents = wantedEvents
    }

    /// Reads `chunk`, calling `emit` for each event it completes.
    public mutating func feed(_ chunk: Data, emit: (JFRTextEvent) -> Void) {
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: 0x0A) {
            if pending.isEmpty {
                process(line: chunk[start..<newline], emit: emit)
            } else {
                pending.append(contentsOf: chunk[start..<newline])
                process(line: pending[...], emit: emit)
                pending.removeAll(keepingCapacity: true)
            }
            start = chunk.index(after: newline)
        }
        if start < chunk.endIndex { pending.append(contentsOf: chunk[start...]) }
    }

    /// Processes a last line that has no trailing newline.
    public mutating func finish(emit: (JFRTextEvent) -> Void) {
        if !pending.isEmpty {
            process(line: pending[...], emit: emit)
            pending.removeAll()
        }
    }

    /// Convenience for text already in memory (tests, small files).
    public mutating func parse(_ text: String, emit: (JFRTextEvent) -> Void) {
        feed(Data(text.utf8), emit: emit)
        finish(emit: emit)
    }

    // MARK: - Lines

    private mutating func process<Bytes: BidirectionalCollection>(line bytes: Bytes, emit: (JFRTextEvent) -> Void) where Bytes.Element == UInt8 {
        linesRead += 1
        var indent = 0
        var begin = bytes.startIndex
        while begin < bytes.endIndex, bytes[begin] == 0x20 || bytes[begin] == 0x09 {
            indent += 1
            begin = bytes.index(after: begin)
        }
        var end = bytes.endIndex
        while end > begin {
            let last = bytes[bytes.index(before: end)]
            if last == 0x0D || last == 0x20 { end = bytes.index(before: end) } else { break }
        }
        guard begin < end else { return }
        let text = String(decoding: bytes[begin..<end], as: UTF8.self)

        guard let type = eventType else {
            if indent == 0, text.hasSuffix(" {") {
                eventType = String(text.dropLast(2))
                depth = 1
                inStack = false
                frames.removeAll(keepingCapacity: true)
                truncated = false
                attributes.removeAll(keepingCapacity: true)
            }
            return
        }

        if inStack {
            if text == "]" || text == "]," {
                inStack = false
            } else if text == "..." {
                truncated = true
            } else {
                frames.append(frameID(for: text))
            }
            return
        }
        if text == "}" || text == "]" || text == "}," || text == "]," {
            depth -= 1
            if depth <= 0 {
                if wantedEvents?.contains(type) ?? true { emit(makeEvent(type: type)) }
                eventType = nil
                depth = 0
            }
            return
        }
        if depth == 1, text == "stackTrace = [" {
            inStack = true
            return
        }
        if text.hasSuffix("{") || text.hasSuffix("[") {
            depth += 1
            return
        }
        guard depth == 1, let separator = text.range(of: " = ") else { return }
        let key = String(text[..<separator.lowerBound])
        guard Self.capturedKeys.contains(key) else { return }
        attributes[key] = String(text[separator.upperBound...])
    }

    private func makeEvent(type: String) -> JFRTextEvent {
        let threadText = attributes["sampledThread"] ?? attributes["eventThread"] ?? attributes["thread"]
        let (name, id) = Self.parseThread(threadText)
        return JFRTextEvent(
            type: type, thread: name, threadID: id, frames: frames, isTruncated: truncated, attributes: attributes,
            timeMillis: attributes["startTime"].flatMap(Self.parseTimestamp)
        )
    }

    // MARK: - Values

    private mutating func frameID(for text: String) -> Int32 {
        if let id = frameCache[text] { return id }
        if frameCache.count >= Self.frameCacheLimit { frameCache.removeAll(keepingCapacity: true) }
        let (className, name, parameters, line) = Self.parseFrame(text)
        let method = symbols.internMethod(className: className, name: name, parameters: parameters)
        let id = symbols.internFrame(method: method, line: Int32(truncatingIfNeeded: line))
        frameCache[text] = id
        return id
    }

    /// `pkg.Class.method(int, String) line: 12` → class, method, parameters, line.
    /// Hidden and lambda classes (`Foo$$Lambda/0x…`) keep their names as printed.
    static func parseFrame(_ text: String) -> (className: String, name: String, parameters: String, line: Int) {
        var location = Substring(text)
        var line = 0
        if let range = text.range(of: " line: ", options: .backwards) {
            line = Int(text[range.upperBound...].trimmingCharacters(in: .whitespaces)) ?? 0
            location = text[..<range.lowerBound]
        }
        guard let open = location.firstIndex(of: "(") else {
            return splitQualified(String(location), parameters: "", line: line)
        }
        let close = location.lastIndex(of: ")") ?? location.endIndex
        let parameters = open < close ? String(location[location.index(after: open)..<close]) : ""
        return splitQualified(String(location[..<open]), parameters: parameters, line: line)
    }

    private static func splitQualified(_ qualified: String, parameters: String, line: Int)
        -> (className: String, name: String, parameters: String, line: Int) {
        guard let dot = qualified.lastIndex(of: ".") else { return ("", qualified, parameters, line) }
        return (String(qualified[..<dot]), String(qualified[qualified.index(after: dot)...]), parameters, line)
    }

    /// `"main" (javaThreadId = 3)` → `main`, 3. An OS thread id (`osThreadId`) counts as the id too.
    static func parseThread(_ text: String?) -> (String?, Int?) {
        guard var text else { return (nil, nil) }
        var id: Int?
        if let open = text.range(of: " (", options: .backwards), text.hasSuffix(")") {
            let inside = text[open.upperBound...].dropLast()
            if let equals = inside.range(of: " = ") { id = Int(inside[equals.upperBound...]) }
            text = String(text[..<open.lowerBound])
        }
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        return (text, id)
    }

    /// `142.9 kB` → 142 900; JFR formats with decimal prefixes.
    public static func parseBytes(_ text: String) -> Int? {
        let parts = text.split(separator: " ")
        guard let first = parts.first, let value = Double(first) else { return nil }
        let unit = parts.count > 1 ? parts[1] : "bytes"
        let scale: Double
        switch unit {
        case "bytes", "byte", "B": scale = 1
        case "kB", "KB": scale = 1_000
        case "MB": scale = 1_000_000
        case "GB": scale = 1_000_000_000
        case "TB": scale = 1_000_000_000_000
        default: return nil
        }
        return Int(value * scale)
    }

    /// `0.841 ms` → 841 000.
    public static func parseNanoseconds(_ text: String) -> Int? {
        let parts = text.split(separator: " ")
        guard let first = parts.first, let value = Double(first), parts.count > 1 else { return nil }
        let scale: Double
        switch parts[1] {
        case "ns": scale = 1
        case "us", "µs": scale = 1_000
        case "ms": scale = 1_000_000
        case "s": scale = 1_000_000_000
        case "m", "min": scale = 60_000_000_000
        default: return nil
        }
        return Int(value * scale)
    }

    /// `23:59:46.198 (2026-10-13)` (what `jfr print` writes: local time, then the date) or an ISO
    /// `2026-10-13T23:59:46.198…` form, in milliseconds since 1970 on that clock. A time with no date
    /// counts from day zero. The zone is ignored: the values of one recording are compared with each
    /// other, and the printer uses one zone throughout.
    public static func parseTimestamp(_ text: String) -> Int64? {
        var numbers: [(value: Int, digits: Int)] = []
        var value = 0
        var digits = 0
        for byte in text.utf8 {
            if byte >= 0x30, byte <= 0x39 {
                value = value &* 10 &+ Int(byte - 0x30)
                digits += 1
            } else {
                if digits > 0 { numbers.append((value, digits)) }
                value = 0
                digits = 0
                if numbers.count == 7 { break }
            }
        }
        if digits > 0, numbers.count < 7 { numbers.append((value, digits)) }
        guard numbers.count >= 3 else { return nil }
        let isoFirst = numbers[0].digits == 4
        let year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
        var millis = 0
        if isoFirst {
            guard numbers.count >= 6 else { return nil }
            (year, month, day) = (numbers[0].value, numbers[1].value, numbers[2].value)
            (hour, minute, second) = (numbers[3].value, numbers[4].value, numbers[5].value)
            if numbers.count > 6 { millis = fractionalMilliseconds(numbers[6]) }
        } else {
            (hour, minute, second) = (numbers[0].value, numbers[1].value, numbers[2].value)
            var next = 3
            // `.198` is followed by the date; a time without milliseconds goes straight to it.
            if numbers.count > next, numbers[next].digits <= 3, numbers.count == 4 || numbers.count == 7 {
                millis = fractionalMilliseconds(numbers[next])
                next += 1
            }
            if numbers.count >= next + 3 {
                (year, month, day) = (numbers[next].value, numbers[next + 1].value, numbers[next + 2].value)
            } else {
                (year, month, day) = (1970, 1, 1)
            }
        }
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 62 else { return nil }
        // Days from civil (H. Hinnant's algorithm), proleptic Gregorian.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return Int64(days) * 86_400_000 + Int64(hour * 3_600_000 + minute * 60_000 + second * 1_000 + millis)
    }

    /// `.5` is 500 ms and `.198765` is 198 ms: the digits after the point, to three places.
    private static func fractionalMilliseconds(_ part: (value: Int, digits: Int)) -> Int {
        var value = part.value
        var digits = part.digits
        while digits > 3 { value /= 10; digits -= 1 }
        while digits < 3 { value *= 10; digits += 1 }
        return value
    }

    /// `0.12%` → 0.0012; `37` with no sign is returned as written.
    public static func parseFraction(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") { return Double(trimmed.dropLast()).map { $0 / 100 } }
        return Double(trimmed)
    }
}
