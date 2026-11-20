import Foundation

/// How the JVM laid objects out, which HPROF does not record: the object header and the size of a
/// reference field. HPROF writes every reference as a full id, so field bytes in the dump overcount
/// under compressed oops; shallow sizes are computed from this instead.
public struct HeapObjectLayout: Hashable, Sendable, CustomStringConvertible {
    /// Bytes before the first field: 8 (compact headers, JDK 24+), 12 (compressed class pointers) or 16.
    public let headerSize: Int
    /// Bytes per reference field and object-array element: 4 (compressed oops) or 8.
    public let referenceSize: Int

    public init(headerSize: Int, referenceSize: Int) {
        self.headerSize = headerSize
        self.referenceSize = referenceSize
    }

    /// The 64-bit default for heaps under 32 GB: compressed oops and class pointers.
    public static let compressed = HeapObjectLayout(headerSize: 12, referenceSize: 4)
    /// No compression (heaps of 32 GB and more before JDK 15, or `-XX:-UseCompressedOops -XX:-UseCompressedClassPointers`).
    public static let uncompressed = HeapObjectLayout(headerSize: 16, referenceSize: 8)
    /// Large heap on JDK 15+: class pointers stay compressed, oops do not.
    public static let compressedClassPointersOnly = HeapObjectLayout(headerSize: 12, referenceSize: 8)
    /// `-XX:+UseCompactObjectHeaders` (JDK 24+) with compressed oops.
    public static let compactHeaders = HeapObjectLayout(headerSize: 8, referenceSize: 4)
    /// Compact headers on a large heap.
    public static let compactHeadersWideReferences = HeapObjectLayout(headerSize: 8, referenceSize: 8)
    /// `-XX:-UseCompressedClassPointers` with compressed oops.
    public static let wideHeaderNarrowReferences = HeapObjectLayout(headerSize: 16, referenceSize: 4)

    /// Every layout a 64-bit dump is tested against, in order of preference on a tie.
    public static let candidates: [HeapObjectLayout] = [
        .compressed, .uncompressed, .compressedClassPointersOnly, .compactHeaders,
        .compactHeadersWideReferences, .wideHeaderNarrowReferences
    ]

    /// A 32-bit JVM (4-byte ids): an 8-byte header and 4-byte references.
    public static let thirtyTwoBit = HeapObjectLayout(headerSize: 8, referenceSize: 4)

    /// What is assumed when the dump gives no evidence.
    public static func fallback(idSize: Int) -> HeapObjectLayout {
        idSize == 4 ? .thirtyTwoBit : .compressed
    }

    public var description: String {
        switch self {
        case .compressed: return "Compressed oops and class pointers (12-byte header, 4-byte references)"
        case .uncompressed: return "Uncompressed (16-byte header, 8-byte references)"
        case .compressedClassPointersOnly: return "Compressed class pointers only (12-byte header, 8-byte references)"
        case .compactHeaders: return "Compact object headers (8-byte header, 4-byte references)"
        default: return "\(headerSize)-byte header, \(referenceSize)-byte references"
        }
    }

    /// The short form for a status line: `12 + 4`.
    public var shortDescription: String { "\(headerSize)-byte header, \(referenceSize)-byte refs" }

    /// An instance with `primitiveBytes` of non-reference fields and `references` reference fields
    /// (the whole class chain), rounded to the 8-byte object alignment.
    @inline(__always)
    public func instanceSize(primitiveBytes: Int, references: Int) -> Int {
        Self.align(headerSize + primitiveBytes + references * referenceSize)
    }

    /// An array of `length` elements of `elementSize` bytes: header, a 4-byte length, the elements
    /// (8-byte elements start 8-aligned), rounded to 8.
    @inline(__always)
    public func arraySize(length: Int, elementSize: Int) -> Int {
        var base = headerSize + 4
        if elementSize == 8 { base = Self.align(base) }
        return Self.align(base + length * elementSize)
    }

    @inline(__always)
    static func align(_ size: Int) -> Int { (size + 7) & ~7 }
}

/// Two neighbouring objects of one heap segment, `gap` bytes apart in the dump's addresses: the
/// first one's real size when the heap was dense there. Collected while walking, matched against
/// each candidate layout afterwards (when the class table is complete).
struct HeapGapSample: Sendable {
    enum Shape: Sendable {
        case instance(classID: UInt64)
        case primitiveArray(elementSize: Int, length: Int)
        case objectArray(length: Int)
    }

    let gap: Int
    let shape: Shape
}

enum HeapLayoutDetector {
    struct Result: Sendable, Equatable {
        let layout: HeapObjectLayout
        /// Share of samples whose gap the layout predicts exactly; nil without samples.
        let confidence: Double?
        let sampleCount: Int
    }

    /// The candidate that predicts the most gaps exactly. Fewer than 20 samples, or a best match
    /// under a quarter of them, is no evidence: the fallback wins.
    static func detect(
        samples: [HeapGapSample], idSize: Int,
        instanceShape: (UInt64) -> (primitiveBytes: Int, references: Int)?
    ) -> Result {
        let fallback = HeapObjectLayout.fallback(idSize: idSize)
        guard idSize == 8 else {
            return Result(layout: fallback, confidence: nil, sampleCount: samples.count)
        }
        var best = (layout: fallback, matches: -1)
        var usable = 0
        for (index, layout) in HeapObjectLayout.candidates.enumerated() {
            var matches = 0
            var counted = 0
            for sample in samples {
                let predicted: Int
                switch sample.shape {
                case .instance(let classID):
                    guard let shape = instanceShape(classID) else { continue }
                    predicted = layout.instanceSize(primitiveBytes: shape.primitiveBytes, references: shape.references)
                case .primitiveArray(let elementSize, let length):
                    predicted = layout.arraySize(length: length, elementSize: elementSize)
                case .objectArray(let length):
                    predicted = layout.arraySize(length: length, elementSize: layout.referenceSize)
                }
                counted += 1
                if predicted == sample.gap { matches += 1 }
            }
            if index == 0 { usable = counted }
            if matches > best.matches { best = (layout, matches) }
        }
        guard usable >= 20, best.matches * 4 >= usable else {
            return Result(layout: fallback, confidence: nil, sampleCount: usable)
        }
        return Result(layout: best.layout, confidence: Double(best.matches) / Double(usable), sampleCount: usable)
    }
}
