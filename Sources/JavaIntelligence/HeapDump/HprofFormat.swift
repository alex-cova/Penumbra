import Foundation

/// The vocabulary of the HPROF binary heap dump format (`JAVA PROFILE 1.0.1` / `1.0.2`), as HotSpot
/// writes it (`heapDumper.cpp`). Every multi-byte value is big-endian; an "id" is 4 or 8 bytes,
/// given once in the header.
public enum HprofFormat {
    /// The header string before its NUL. 1.0.2 adds HEAP_DUMP_SEGMENT; 1.0.3 is Android's dialect.
    public static let supportedVersions: Set<String> = ["JAVA PROFILE 1.0.1", "JAVA PROFILE 1.0.2"]
    public static let androidVersion = "JAVA PROFILE 1.0.3"

    /// Top-level record tags (record header: tag u1, time offset u4, body length u4).
    enum Tag: UInt8 {
        case utf8 = 0x01
        case loadClass = 0x02
        case unloadClass = 0x03
        case stackFrame = 0x04
        case stackTrace = 0x05
        case allocSites = 0x06
        case heapSummary = 0x07
        case startThread = 0x0A
        case endThread = 0x0B
        case heapDump = 0x0C
        case cpuSamples = 0x0D
        case controlSettings = 0x0E
        case heapDumpSegment = 0x1C
        case heapDumpEnd = 0x2C
    }

    /// Sub-record tags inside HEAP_DUMP / HEAP_DUMP_SEGMENT bodies. Their lengths are implied by
    /// their layout, so an unknown tag ends what can be read of that segment.
    enum SubTag {
        static let rootUnknown: UInt8 = 0xFF
        static let rootJNIGlobal: UInt8 = 0x01
        static let rootJNILocal: UInt8 = 0x02
        static let rootJavaFrame: UInt8 = 0x03
        static let rootNativeStack: UInt8 = 0x04
        static let rootStickyClass: UInt8 = 0x05
        static let rootThreadBlock: UInt8 = 0x06
        static let rootMonitorUsed: UInt8 = 0x07
        static let rootThreadObject: UInt8 = 0x08
        static let classDump: UInt8 = 0x20
        static let instanceDump: UInt8 = 0x21
        static let objectArrayDump: UInt8 = 0x22
        static let primitiveArrayDump: UInt8 = 0x23
    }
}

/// A field or array element type as HPROF encodes it.
public enum HprofBasicType: UInt8, Sendable, CaseIterable {
    case object = 2
    case boolean = 4
    case char = 5
    case float = 6
    case double = 7
    case byte = 8
    case short = 9
    case int = 10
    case long = 11

    /// Bytes this type takes in the dump. An object reference takes the id size, whatever the JVM used.
    func size(idSize: Int) -> Int {
        switch self {
        case .object: return idSize
        case .boolean, .byte: return 1
        case .char, .short: return 2
        case .float, .int: return 4
        case .double, .long: return 8
        }
    }

    /// The Java name of a primitive array of this type, `int[]`.
    public var arrayName: String {
        switch self {
        case .object: return "java.lang.Object[]"
        case .boolean: return "boolean[]"
        case .char: return "char[]"
        case .float: return "float[]"
        case .double: return "double[]"
        case .byte: return "byte[]"
        case .short: return "short[]"
        case .int: return "int[]"
        case .long: return "long[]"
        }
    }
}

/// What keeps an object alive, by the root sub-record that named it.
public enum HprofRootKind: String, Sendable, CaseIterable, Hashable {
    case unknown = "Unknown"
    case jniGlobal = "JNI global"
    case jniLocal = "JNI local"
    case javaFrame = "Java frame"
    case nativeStack = "Native stack"
    case stickyClass = "Sticky class"
    case threadBlock = "Thread block"
    case monitorUsed = "Busy monitor"
    case threadObject = "Thread"

    init?(subTag: UInt8) {
        switch subTag {
        case HprofFormat.SubTag.rootUnknown: self = .unknown
        case HprofFormat.SubTag.rootJNIGlobal: self = .jniGlobal
        case HprofFormat.SubTag.rootJNILocal: self = .jniLocal
        case HprofFormat.SubTag.rootJavaFrame: self = .javaFrame
        case HprofFormat.SubTag.rootNativeStack: self = .nativeStack
        case HprofFormat.SubTag.rootStickyClass: self = .stickyClass
        case HprofFormat.SubTag.rootThreadBlock: self = .threadBlock
        case HprofFormat.SubTag.rootMonitorUsed: self = .monitorUsed
        case HprofFormat.SubTag.rootThreadObject: self = .threadObject
        default: return nil
        }
    }
}

public enum HprofError: Error, Equatable, CustomStringConvertible {
    case cannotOpen(String)
    case notAHeapDump
    case unsupportedVersion(String)
    case compressed
    case badIDSize(Int)
    case truncated(at: Int64)
    case malformed(at: Int64, String)

    public var description: String {
        switch self {
        case .cannotOpen(let reason): return "The file could not be opened: \(reason)"
        case .notAHeapDump: return "This is not an HPROF heap dump."
        case .unsupportedVersion(let version):
            if version == HprofFormat.androidVersion {
                return "This is an Android heap dump (\(version)). Convert it with `hprof-conv` first."
            }
            return "Unsupported heap dump format: \(version)."
        case .compressed: return "This heap dump is gzip-compressed. Decompress it (gunzip) and open the .hprof."
        case .badIDSize(let size): return "The heap dump declares an id size of \(size) bytes; only 4 and 8 exist."
        case .truncated(let offset): return "The heap dump ends early, at byte \(offset)."
        case .malformed(let offset, let what): return "Unreadable heap dump record at byte \(offset): \(what)."
        }
    }
}

/// The fixed header: the version string, its NUL, the id size (u4) and the dump time (u8, ms since 1970).
public struct HprofHeader: Sendable, Equatable {
    public let version: String
    public let idSize: Int
    public let timestamp: Date
    /// Where the first record starts.
    public let length: Int

    /// Parses the header from the first bytes of a file.
    public static func parse(_ head: Data) throws -> HprofHeader {
        if head.count >= 2, head[head.startIndex] == 0x1F, head[head.startIndex + 1] == 0x8B { throw HprofError.compressed }
        guard let nul = head.prefix(64).firstIndex(of: 0) else { throw HprofError.notAHeapDump }
        let version = String(decoding: head[head.startIndex..<nul], as: UTF8.self)
        guard version.hasPrefix("JAVA PROFILE ") else { throw HprofError.notAHeapDump }
        guard HprofFormat.supportedVersions.contains(version) else { throw HprofError.unsupportedVersion(version) }
        let start = nul + 1
        guard head.endIndex - start >= 12 else { throw HprofError.truncated(at: Int64(head.count)) }
        let bytes = [UInt8](head[start..<start + 12])
        let idSize = Int(bytes[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard idSize == 4 || idSize == 8 else { throw HprofError.badIDSize(idSize) }
        let millis = bytes[4..<12].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return HprofHeader(
            version: version, idSize: idSize,
            timestamp: Date(timeIntervalSince1970: TimeInterval(millis) / 1000),
            length: start - head.startIndex + 12
        )
    }
}

/// Whether a file is a heap dump, from its first bytes (never its name alone).
public enum HprofDetector {
    /// `JAVA PROFILE 1.0.x` then NUL: any version, so an Android or future dump reaches the viewer
    /// and is told why it cannot be read instead of opening as hex.
    public static func isHeapDump(head: Data) -> Bool {
        let magic = Data("JAVA PROFILE 1.0.".utf8)
        guard head.count >= magic.count + 2, head.prefix(magic.count) == magic else { return false }
        return head.prefix(32).contains(0)
    }

    public static func isHeapDump(at url: URL) -> Bool {
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 32) else { return false }
        return isHeapDump(head: head)
    }

    /// `.hprof` (and `.hprof.gz`), for a name-based hint where the bytes are not at hand.
    public static func hasHeapDumpExtension(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".hprof") || name.hasSuffix(".hprof.gz")
    }
}

/// HPROF class names are JVM internal names: `java/lang/String`, `[Ljava/lang/String;`, `[[I`.
enum HprofClassName {
    static func javaName(_ internalName: String) -> String {
        var dimensions = 0
        var rest = Substring(internalName)
        while rest.first == "[" {
            dimensions += 1
            rest = rest.dropFirst()
        }
        guard dimensions > 0 else { return internalName.replacingOccurrences(of: "/", with: ".") }
        let element: String
        switch rest.first {
        case "L":
            element = String(rest.dropFirst().prefix { $0 != ";" }).replacingOccurrences(of: "/", with: ".")
        case "Z": element = "boolean"
        case "C": element = "char"
        case "F": element = "float"
        case "D": element = "double"
        case "B": element = "byte"
        case "S": element = "short"
        case "I": element = "int"
        case "J": element = "long"
        default: element = String(rest).replacingOccurrences(of: "/", with: ".")
        }
        return element + String(repeating: "[]", count: dimensions)
    }
}
