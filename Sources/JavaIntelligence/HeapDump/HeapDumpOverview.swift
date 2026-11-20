import Foundation

/// The result of `HeapDumpCensus.read`: the dump's header facts, counts, GC roots, the object
/// layout it was judged to use, and a class histogram under that layout (or another candidate).
public struct HeapDumpOverview: Sendable {
    public let url: URL
    public let fileSize: Int64
    public let header: HprofHeader
    /// The layout shallow sizes use: detected, or the fallback when the dump gave no evidence.
    public let layout: HeapObjectLayout
    /// Share of sampled neighbours whose spacing `layout` predicts exactly; nil when it is the fallback.
    public let layoutConfidence: Double?
    public let layoutSampleCount: Int
    /// The layouts `histogram(layout:)` can recompute under.
    public let availableLayouts: [HeapObjectLayout]

    public let instanceCount: Int
    public let objectArrayCount: Int
    public let primitiveArrayCount: Int
    public let classCount: Int
    /// Distinct class loaders that loaded a class in the dump, the bootstrap loader included.
    public let classLoaderCount: Int
    public let rootCounts: [HprofRootKind: Int]
    public let stringCount: Int
    public let stackTraceCount: Int
    /// Where the file stops in the middle of a record, if it does.
    public let truncatedAt: Int64?
    /// Segments that could not be read to their end, at most 20.
    public let problems: [String]
    public let elapsed: TimeInterval
    /// Under `layout`.
    public let histogram: HeapHistogram
    /// At most how many references the dump holds (field slots that could be references, array
    /// elements, statics): what the object index's disk estimate is based on.
    public let referenceSlots: Int

    let aggregates: [Aggregate]

    public var objectCount: Int { instanceCount + objectArrayCount + primitiveArrayCount + classCount }
    public var threadCount: Int { rootCounts[.threadObject] ?? 0 }
    public var rootCount: Int { rootCounts.values.reduce(0, +) }

    /// One histogram row before a layout is chosen: its size under each of `availableLayouts`.
    struct Aggregate: Sendable {
        let name: String
        let kind: HeapClassRow.Kind
        let count: Int
        let sizes: SIMD8<Int64>
        var classID: UInt64?
    }

    /// The histogram under another of `availableLayouts` (the layout override); `layout`'s otherwise.
    public func histogram(layout other: HeapObjectLayout) -> HeapHistogram {
        guard let index = availableLayouts.firstIndex(of: other) else { return histogram }
        return Self.histogram(aggregates, layoutIndex: index)
    }

    static func histogram(_ aggregates: [Aggregate], layoutIndex: Int) -> HeapHistogram {
        let rows = aggregates.enumerated().map { offset, aggregate in
            HeapClassRow(
                id: offset, name: aggregate.name, kind: aggregate.kind, count: aggregate.count,
                shallowBytes: aggregate.sizes[layoutIndex], classID: aggregate.classID
            )
        }
        return HeapHistogram(rows: rows.sorted { ($0.shallowBytes, $1.name) > ($1.shallowBytes, $0.name) })
    }

    // MARK: - Building

    static func make(
        url: URL, fileSize: Int64, header: HprofHeader, topLevel: HeapDumpCensus.TopLevel,
        census: HeapDumpCensus.CensusPart, classNames: [UInt64: String], elapsed: TimeInterval
    ) -> HeapDumpOverview {
        let idSize = header.idSize
        let layouts = idSize == 4 ? [HeapObjectLayout.thirtyTwoBit] : HeapObjectLayout.candidates
        var classes: [UInt64: HeapDumpCensus.ClassInfo] = [:]
        classes.reserveCapacity(census.classes.count)
        for info in census.classes { classes[info.id] = info }

        // Fields of the whole chain, memoized: a class's instance is its own fields plus its supers'.
        var shapes: [UInt64: (primitiveBytes: Int, references: Int)] = [:]
        func shape(of classID: UInt64) -> (primitiveBytes: Int, references: Int)? {
            if let known = shapes[classID] { return known }
            var chain: [HeapDumpCensus.ClassInfo] = []
            var cursor = classID
            var seen = Set<UInt64>()
            while cursor != 0, let info = classes[cursor], seen.insert(cursor).inserted {
                chain.append(info)
                cursor = info.superID
            }
            guard !chain.isEmpty else { return nil }
            let result = chain.reduce((primitiveBytes: 0, references: 0)) {
                ($0.primitiveBytes + $1.declaredPrimitiveBytes, $0.references + $1.declaredReferences)
            }
            shapes[classID] = result
            return result
        }

        let detection = HeapLayoutDetector.detect(samples: census.samples, idSize: idSize, instanceShape: shape(of:))

        func name(_ classID: UInt64) -> String {
            classNames[classID] ?? String(format: "<unknown class 0x%llx>", classID)
        }

        var aggregates: [Aggregate] = []
        var instanceCount = 0
        for (classID, tally) in census.instances {
            instanceCount += tally.count
            var sizes = SIMD8<Int64>()
            let classShape = shape(of: classID)
            for (index, layout) in layouts.enumerated() {
                let each: Int
                if let classShape {
                    each = layout.instanceSize(primitiveBytes: classShape.primitiveBytes, references: classShape.references)
                } else {
                    // No class dump: the dump's own field bytes, which count references at the id size.
                    each = HeapObjectLayout.align(layout.headerSize + tally.fieldBytes / max(tally.count, 1))
                }
                sizes[index] = Int64(each) * Int64(tally.count)
            }
            aggregates.append(Aggregate(name: name(classID), kind: .instance, count: tally.count, sizes: sizes, classID: classID))
        }
        var objectArrayCount = 0
        for (classID, tally) in census.objectArrays {
            objectArrayCount += tally.count
            aggregates.append(Aggregate(
                name: name(classID), kind: .objectArray, count: tally.count,
                sizes: census.objectArraySizes[classID] ?? SIMD8<Int64>(), classID: classID
            ))
        }
        var primitiveArrayCount = 0
        for (rawType, tally) in census.primitiveArrays {
            primitiveArrayCount += tally.count
            aggregates.append(Aggregate(
                name: HprofBasicType(rawValue: rawType)?.arrayName ?? "<type \(rawType)>[]", kind: .primitiveArray,
                count: tally.count, sizes: census.primitiveArraySizes[rawType] ?? SIMD8<Int64>()
            ))
        }
        // Class objects: HPROF writes no INSTANCE_DUMP for a `java.lang.Class`. A mirror is a
        // `Class` instance with the class's static fields stored inside it.
        if !census.classes.isEmpty {
            let classClassID = classNames.first { $0.value == "java.lang.Class" }?.key
            let classShape = classClassID.flatMap(shape(of:)) ?? (primitiveBytes: 0, references: 0)
            var sizes = SIMD8<Int64>()
            for (index, layout) in layouts.enumerated() {
                var total: Int64 = 0
                for info in census.classes {
                    total += Int64(layout.instanceSize(
                        primitiveBytes: classShape.primitiveBytes + info.staticPrimitiveBytes,
                        references: classShape.references + info.staticReferences
                    ))
                }
                sizes[index] = total
            }
            aggregates.append(Aggregate(name: "java.lang.Class", kind: .classObject, count: census.classes.count, sizes: sizes))
        }

        let layoutIndex = layouts.firstIndex(of: detection.layout) ?? 0
        let referenceSlots = census.instances.values.reduce(0) { $0 + $1.fieldBytes / idSize }
            + census.objectArrays.values.reduce(0) { $0 + $1.elements }
            + census.classes.reduce(0) { $0 + $1.staticReferences + 2 }
        var loaders = Set(census.classes.map(\.loaderID))
        loaders.insert(0)
        return HeapDumpOverview(
            url: url, fileSize: fileSize, header: header,
            layout: layouts[layoutIndex], layoutConfidence: detection.confidence,
            layoutSampleCount: detection.sampleCount, availableLayouts: layouts,
            instanceCount: instanceCount, objectArrayCount: objectArrayCount,
            primitiveArrayCount: primitiveArrayCount, classCount: census.classes.count,
            classLoaderCount: loaders.count, rootCounts: census.roots,
            stringCount: topLevel.strings.count, stackTraceCount: topLevel.stackTraceCount,
            truncatedAt: topLevel.truncatedAt, problems: census.problems, elapsed: elapsed,
            histogram: histogram(aggregates, layoutIndex: layoutIndex), referenceSlots: referenceSlots,
            aggregates: aggregates
        )
    }
}

/// One histogram line: a class (or array type, or a package when grouped) with how many objects
/// it has and their shallow size.
public struct HeapClassRow: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case instance
        case objectArray
        case primitiveArray
        /// `java.lang.Class` mirrors (class dumps).
        case classObject
        /// A grouping row: a package and everything in it.
        case package
    }

    public let id: Int
    public let name: String
    public let kind: Kind
    public let count: Int
    public let shallowBytes: Int64
    /// The class object's id for an instance or object array row; nil for the rest.
    public let classID: UInt64?
    /// The class's retained size once an object index with dominators is open; nil before, and
    /// for package rows (a package's classes can dominate one another).
    public var retainedBytes: Int64?
    /// For sorting: rows without a retained size go last.
    public var retainedSortKey: Int64 { retainedBytes ?? -1 }

    public init(id: Int, name: String, kind: Kind, count: Int, shallowBytes: Int64, classID: UInt64? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.count = count
        self.shallowBytes = shallowBytes
        self.classID = classID
    }

    /// The package a class belongs to; an array's is its element class's. Primitive arrays and the
    /// default package get a bracketed name so they sort apart.
    public var packageName: String {
        var element = Substring(name)
        while element.hasSuffix("[]") { element = element.dropLast(2) }
        if HeapClassRow.primitiveNames.contains(String(element)) { return "(primitive arrays)" }
        // `a.b.Outer$Inner` is in `a.b`; a nested class has no dot after its `$`.
        guard let dot = element.lastIndex(of: ".") else { return "(default package)" }
        return String(element[..<dot])
    }

    public static let primitiveNames: Set<String> = ["boolean", "char", "float", "double", "byte", "short", "int", "long"]
}

/// Rows sorted by shallow size (largest first), with totals, a filter and a package grouping.
public struct HeapHistogram: Sendable {
    public let rows: [HeapClassRow]
    public let totalCount: Int
    public let totalShallowBytes: Int64

    public init(rows: [HeapClassRow]) {
        self.rows = rows
        self.totalCount = rows.reduce(0) { $0 + $1.count }
        self.totalShallowBytes = rows.reduce(0) { $0 + $1.shallowBytes }
    }

    /// Rows whose name matches: a `JavaClassPattern` when the text has a `*`, otherwise a
    /// case-insensitive substring (what a user types to find `HashMap`). Empty text keeps all.
    public func filtered(_ text: String) -> [HeapClassRow] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return rows }
        if trimmed.contains("*"), let pattern = JavaClassPattern(trimmed) {
            return rows.filter { pattern.matches(className: $0.name) }
        }
        return rows.filter { $0.name.range(of: trimmed, options: .caseInsensitive) != nil }
    }

    /// One row per package, summed, largest first.
    public func groupedByPackage() -> HeapHistogram {
        var totals: [String: (count: Int, bytes: Int64)] = [:]
        for row in rows {
            let key = row.packageName
            totals[key, default: (0, 0)].count += row.count
            totals[key, default: (0, 0)].bytes += row.shallowBytes
        }
        let grouped = totals.sorted { ($0.value.bytes, $1.key) > ($1.value.bytes, $0.key) }
            .enumerated()
            .map { offset, entry in
                HeapClassRow(id: offset, name: entry.key, kind: .package, count: entry.value.count, shallowBytes: entry.value.bytes)
            }
        return HeapHistogram(rows: grouped)
    }
}
