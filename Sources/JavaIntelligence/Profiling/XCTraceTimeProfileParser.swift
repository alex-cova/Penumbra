import Foundation

/// Reads the `time-profile` table of an Instruments recording (`xctrace export … --xpath
/// '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'`) into the profile model the flame graph, hot
/// methods and call tree already show for a Flight Recorder file.
///
/// A sample is a row with a time, a thread and a backtrace, innermost frame first. The export interns what repeats:
/// a thread, a frame, a binary or a whole backtrace is written once with an `id` and named by `ref` afterwards, so
/// the parser keeps those tables and reads the file as a stream. A frame becomes a method whose "class" is the
/// binary it is in (`spin`, `libswiftCore`), which is how the graph colours it, and whose name is the demangled
/// symbol the tool printed. Instruments records no source line, so none is shown. Every sample counts one.
public enum XCTraceTimeProfileParser {
    public enum ParseError: Error, LocalizedError, Equatable {
        case unreadable
        case malformed(String)
        case noSamples

        public var errorDescription: String? {
            switch self {
            case .unreadable: "The Instruments export could not be read."
            case .malformed(let reason): "The Instruments export is not valid XML: \(reason)"
            case .noSamples: "The recording holds no time-profile samples."
            }
        }
    }

    public static func parse(_ data: Data) throws -> JavaProfile {
        try run(XMLParser(data: data))
    }

    /// Streams the file, so a large export is never held in memory twice.
    public static func parse(contentsOf url: URL) throws -> JavaProfile {
        guard let stream = InputStream(url: url) else { throw ParseError.unreadable }
        return try run(XMLParser(stream: stream))
    }

    private static func run(_ parser: XMLParser) throws -> JavaProfile {
        parser.shouldResolveExternalEntities = false
        let reader = Reader()
        parser.delegate = reader
        guard parser.parse() else {
            throw ParseError.malformed(parser.parserError?.localizedDescription ?? "unknown error")
        }
        guard reader.samples > 0 else { throw ParseError.noSamples }
        return reader.profile
    }

    /// The thread as a person names it: "Main Thread (0x1f3) (spin, pid: 42)" is "Main Thread (0x1f3)".
    static func threadName(from formatted: String) -> String {
        guard let range = formatted.range(of: #"\s*\([^()]*pid: \d+\)\s*$"#, options: .regularExpression) else { return formatted }
        return String(formatted[..<range.lowerBound])
    }

    /// The binary as the graph groups it: `libswiftCore.dylib` is `libswiftCore`.
    static func moduleName(from binary: String) -> String {
        for suffix in [".dylib", ".framework", ".so"] where binary.hasSuffix(suffix) { return String(binary.dropLast(suffix.count)) }
        return binary
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var profile = JavaProfile()
        var samples = 0

        // What the export interned, by its `id`.
        private var times: [String: Int64] = [:]
        private var threads: [String: String] = [:]
        private var binaries: [String: String] = [:]
        private var frames: [String: Int32] = [:]
        private var backtraces: [String: [Int32]] = [:]

        // The row being read.
        private var inRow = false
        private var time: Int64?
        private var thread: String?
        private var stack: [Int32] = []

        // The element being read.
        private var path: [String] = []
        private var text = ""
        private var timeID: String?
        private var backtraceID: String?
        private var collectingBacktrace = false
        private var frameID: String?
        private var frameName: String?
        private var frameBinary: String?

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes attributeDict: [String: String]
        ) {
            let parent = path.last
            path.append(name)
            text = ""
            switch name {
            case "row":
                inRow = true
                time = nil
                thread = nil
                stack = []
            case "sample-time" where inRow:
                if let ref = attributeDict["ref"] { time = times[ref] } else { timeID = attributeDict["id"] }
            case "thread" where inRow && parent == "row":
                if let ref = attributeDict["ref"] {
                    thread = threads[ref]
                } else if let id = attributeDict["id"], let formatted = attributeDict["fmt"] {
                    let name = XCTraceTimeProfileParser.threadName(from: formatted)
                    threads[id] = name
                    thread = name
                }
            case "tagged-backtrace" where inRow, "backtrace" where inRow:
                if let ref = attributeDict["ref"] {
                    stack = backtraces[ref] ?? []
                } else {
                    backtraceID = attributeDict["id"]
                    collectingBacktrace = true
                    stack = []
                }
            case "frame" where collectingBacktrace:
                if let ref = attributeDict["ref"] {
                    if let known = frames[ref] { stack.append(known) }
                    frameID = nil
                    frameName = nil
                } else {
                    frameID = attributeDict["id"]
                    frameName = attributeDict["name"] ?? attributeDict["addr"] ?? "?"
                    frameBinary = nil
                }
            case "binary" where collectingBacktrace:
                if let ref = attributeDict["ref"] {
                    frameBinary = binaries[ref]
                } else if let id = attributeDict["id"] {
                    let module = XCTraceTimeProfileParser.moduleName(from: attributeDict["name"] ?? "")
                    binaries[id] = module
                    frameBinary = module
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if path.last == "sample-time" { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { path.removeLast() }
            switch name {
            case "sample-time" where inRow:
                if let value = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    time = value
                    if let id = timeID { times[id] = value }
                }
                timeID = nil
            case "frame" where collectingBacktrace:
                guard let name = frameName else { break }
                let method = profile.symbols.internMethod(className: frameBinary ?? "", name: name, parameters: "")
                let frame = profile.symbols.internFrame(method: method, line: 0)
                if let id = frameID { frames[id] = frame }
                stack.append(frame)
                frameID = nil
                frameName = nil
            case "tagged-backtrace" where inRow, "backtrace" where inRow:
                if collectingBacktrace, let id = backtraceID { backtraces[id] = stack }
                collectingBacktrace = false
                backtraceID = nil
            case "row":
                if !stack.isEmpty {
                    profile.ingest(JFRTextEvent(
                        type: JavaFlightRecorder.EventType.executionSample, thread: thread, frames: stack,
                        timeMillis: time.map { $0 / 1_000_000 }
                    ))
                    samples += 1
                }
                inRow = false
            default:
                break
            }
        }
    }
}
