import Foundation
@testable import JavaIntelligence
import XCTest

/// A dump whose objects are `Object[]` arrays holding their successors' ids, so any graph can be
/// written; `roots` get ROOT_UNKNOWN records. Under the compressed layout an array of `n`
/// elements is `align8(16 + 4n)` bytes.
private struct GraphDump {
    static let arrayClass: UInt64 = 0x130
    var edges: [UInt64: [UInt64]] = [:]
    var order: [UInt64] = []
    var roots: [UInt64] = []

    mutating func node(_ id: UInt64, _ successors: [UInt64] = []) {
        if edges[id] == nil { order.append(id) }
        edges[id] = successors
    }

    func writer() -> HprofTestWriter {
        var writer = HprofTestWriter()
        writer.loadClass(0x100, name: "java/lang/Object")
        writer.loadClass(Self.arrayClass, name: "[Ljava/lang/Object;")
        writer.segment { s in
            s.classDump(0x100)
            s.classDump(Self.arrayClass, superID: 0x100)
        }
        writer.segment { s in
            for id in order { s.objectArray(id, classID: Self.arrayClass, elements: edges[id] ?? []) }
            for root in roots { s.root(.unknown, root) }
        }
        return writer
    }

    static func size(_ length: Int) -> Int64 { Int64(HeapObjectLayout.compressed.arraySize(length: length, elementSize: 4)) }
}

final class HeapDominatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HeapDominatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func build(_ writer: HprofTestWriter, name: String = "graph") async throws -> HeapIndex {
        let url = directory.appendingPathComponent("\(name).hprof")
        try writer.write(to: url)
        return try await HeapIndexBuilder.build(
            dump: url, into: directory.appendingPathComponent("\(name)-index"), layout: .compressed, maxConcurrency: 4
        )
    }

    /// The idom of each id, by id (0 for the super-root), nil when unreachable.
    private func idoms(_ index: HeapIndex, _ ids: [UInt64]) throws -> [UInt64: UInt64?] {
        var result: [UInt64: UInt64?] = [:]
        for id in ids {
            let n = try XCTUnwrap(index.number(ofID: id))
            // `updateValue`, since assigning a nil value through the subscript would remove the key.
            result.updateValue(index.dominator(of: n).map { $0 == 0 ? 0 : index.id(of: $0) }, forKey: id)
        }
        return result
    }

    func testTheLengauerTarjanPaperGraph() async throws {
        // R=1 A=2 B=3 C=4 D=5 E=6 F=7 G=8 H=9 I=10 J=11 K=12 L=13, ids 0x1000 + letter.
        func id(_ letter: Int) -> UInt64 { 0x1000 + UInt64(letter) * 0x40 }
        let (r, a, b, c, d, e, f, g, h, i, j, k, l) = (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13)
        var graph = GraphDump()
        let spec: [(Int, [Int])] = [
            (r, [a, b, c]), (a, [d]), (b, [a, d, e]), (c, [f, g]), (d, [l]), (e, [h]), (f, [i]),
            (g, [i, j]), (h, [e, k]), (i, [k]), (j, [i]), (k, [i, r]), (l, [h])
        ]
        for (node, successors) in spec { graph.node(id(node), successors.map(id)) }
        graph.roots = [id(r)]
        let index = try await build(graph.writer())
        let expected: [Int: Int] = [a: r, b: r, c: r, d: r, e: r, f: c, g: c, h: r, i: r, j: g, k: r, l: d]
        let found = try idoms(index, spec.map { id($0.0) })
        for (node, dominator) in expected {
            XCTAssertEqual(found[id(node)], id(dominator), "idom of \(node)")
        }
        XCTAssertEqual(found[id(r)], 0, "the root hangs off the super-root")
        XCTAssertEqual(index.retainedSize(of: 0), spec.reduce(Int64(0)) { $0 + GraphDump.size($1.1.count) })
        XCTAssertEqual(index.retainedSize(of: try XCTUnwrap(index.number(ofID: id(r)))), index.retainedSize(of: 0))
        // C keeps F, G and J (I is shared with the rest).
        let cRetained = index.retainedSize(of: try XCTUnwrap(index.number(ofID: id(c))))
        XCTAssertEqual(cRetained, GraphDump.size(2) + GraphDump.size(1) + GraphDump.size(2) + GraphDump.size(1))
        XCTAssertEqual(index.reachableCount, 13)
        XCTAssertEqual(index.unreachableCount, 2, "the two class objects no root names")
    }

    func testWeakReferencesDoNotKeepObjectsAndGarbageIsCounted() async throws {
        var writer = HprofTestWriter()
        var names: [String: UInt64] = [:]
        let referent = writer.name("referent", cache: &names)
        let field = writer.name("value", cache: &names)
        writer.loadClass(0x100, name: "java/lang/Object")
        writer.loadClass(0x110, name: "java/lang/ref/Reference")
        writer.loadClass(0x120, name: "java/lang/ref/WeakReference")
        writer.loadClass(0x130, name: "Box")
        writer.segment { s in
            s.classDump(0x100)
            s.classDump(0x110, superID: 0x100, namedFields: [(referent, .object)])
            s.classDump(0x120, superID: 0x110)
            s.classDump(0x130, superID: 0x100, namedFields: [(field, .object)])
            s.instance(0x1000, classID: 0x120, values: [.ref(0x2000)])  // weak → 0x2000, a root
            s.instance(0x2000, classID: 0x130, values: [.ref(0)])       // only weakly held: garbage
            s.instance(0x3000, classID: 0x120, values: [.ref(0x4000)])  // weak → 0x4000
            s.instance(0x4000, classID: 0x130, values: [.ref(0)])
            s.instance(0x5000, classID: 0x130, values: [.ref(0x4000)])  // strong → 0x4000, a root
            s.instance(0x6000, classID: 0x130, values: [.ref(0)])       // nothing at all
            s.root(.javaFrame, 0x1000)
            s.root(.javaFrame, 0x3000)
            s.root(.javaFrame, 0x5000)
        }
        let index = try await build(writer)
        let found = try idoms(index, [0x2000, 0x4000, 0x6000, 0x5000])
        XCTAssertEqual(found[0x2000], .some(nil), "only a referent points to it")
        XCTAssertEqual(found[0x4000], 0x5000, "the strong holder dominates, not the weak one")
        XCTAssertEqual(found[0x6000], .some(nil))
        XCTAssertEqual(found[0x5000], 0)
        let box = try XCTUnwrap(index.classes.firstIndex { $0.name == "Box" }).asInt32
        let weakOnly = try XCTUnwrap(index.number(ofID: 0x2000))
        let nothing = try XCTUnwrap(index.number(ofID: 0x6000))
        // Held only by a referent: not kept alive, not garbage either — its own bucket.
        XCTAssertEqual(index.reachability(of: weakOnly), .weak)
        XCTAssertEqual(index.reachability(of: nothing), .unreachable)
        XCTAssertEqual(index.reachability(of: try XCTUnwrap(index.number(ofID: 0x4000))), .strong)
        XCTAssertEqual(index.weaklyReachableClasses().map { "\($0.name) \($0.count)" }, ["Box 1"])
        XCTAssertTrue(index.unreachableClasses().contains { $0.group == box && $0.count == 1 }, "only 0x6000 is garbage")
        XCTAssertEqual(index.weaklyReachableCount, 1)
        XCTAssertEqual(index.retainedSize(of: weakOnly), 0)
        XCTAssertEqual(index.pathToRoot(of: weakOnly), [], "no strong path")
        XCTAssertEqual(index.pathToRoot(of: weakOnly, includingWeak: true).map { index.id(of: $0) }, [0x2000, 0x1000])
        XCTAssertTrue(index.isWeakLink(weakOnly))
        XCTAssertFalse(index.isWeakLink(try XCTUnwrap(index.number(ofID: 0x4000))))
        XCTAssertEqual(index.pathToRoot(of: nothing, includingWeak: true), [])
        XCTAssertEqual(index.mergedPathsToRoots(of: [weakOnly]), [], "merged paths are strong only")
        XCTAssertEqual(index.reachableCount + index.weaklyReachableCount + index.unreachableCount, index.objectCount)
    }

    func testClassRetainedCountsALinkedListOnce() async throws {
        var writer = HprofTestWriter()
        var names: [String: UInt64] = [:]
        let next = writer.name("next", cache: &names)
        writer.loadClass(0x100, name: "java/lang/Object")
        writer.loadClass(0x110, name: "Node")
        writer.segment { s in
            s.classDump(0x100)
            s.classDump(0x110, superID: 0x100, namedFields: [(next, .object)])
            s.instance(0x1000, classID: 0x110, values: [.ref(0x1100)])
            s.instance(0x1100, classID: 0x110, values: [.ref(0x1200)])
            s.instance(0x1200, classID: 0x110, values: [.ref(0)])
            s.instance(0x2000, classID: 0x110, values: [.ref(0)])
            s.root(.javaFrame, 0x1000)
            s.root(.javaFrame, 0x2000)
        }
        let index = try await build(writer)
        let node = Int32(try XCTUnwrap(index.classes.firstIndex { $0.name == "Node" }))
        let first = index.retainedSize(of: try XCTUnwrap(index.number(ofID: 0x1000)))
        let lone = index.retainedSize(of: try XCTUnwrap(index.number(ofID: 0x2000)))
        XCTAssertEqual(first, 3 * 16, "Node is 12 + 4 → 16, three of them")
        XCTAssertEqual(index.retainedSize(ofGroup: node), first + lone, "not 48 + 32 + 16 + 16")
        let order = index.instances(ofGroup: node, order: .largestRetainedFirst, limit: 4).map { index.id(of: $0) }
        XCTAssertEqual(order.first, 0x1000)
        let held = index.retainedClasses(of: try XCTUnwrap(index.number(ofID: 0x1000)))
        XCTAssertTrue(held.complete)
        XCTAssertEqual(held.classes.map(\.count), [3])
        XCTAssertEqual(held.classes.first?.bytes, 48)
        XCTAssertEqual(index.dominatorChildren(of: 0, range: 0..<10).map { index.id(of: $0) }, [0x1000, 0x2000], "largest first")
    }

    func testShortestAndMergedPathsToRoots() async throws {
        var graph = GraphDump()
        // r → a → b → x, r → c → x, r → c → y; s → y.
        graph.node(0x1000, [0x2000, 0x4000])  // r
        graph.node(0x2000, [0x3000])          // a
        graph.node(0x3000, [0x5000])          // b
        graph.node(0x4000, [0x5000, 0x6000])  // c
        graph.node(0x5000)                    // x
        graph.node(0x6000)                    // y
        graph.node(0x7000, [0x6000])          // s
        graph.roots = [0x1000, 0x7000]
        let index = try await build(graph.writer())
        func n(_ id: UInt64) throws -> Int32 { try XCTUnwrap(index.number(ofID: id)) }
        XCTAssertEqual(index.pathToRoot(of: try n(0x5000)).map { index.id(of: $0) }, [0x5000, 0x4000, 0x1000])
        XCTAssertEqual(index.pathToRoot(of: try n(0x1000)).map { index.id(of: $0) }, [0x1000])
        XCTAssertEqual(index.roots(of: try n(0x1000)).map(\.kind), [.unknown])
        let merged = index.mergedPathsToRoots(of: [try n(0x5000), try n(0x6000)])
        let lines = merged.map { "\($0.depth) \(String(index.id(of: $0.object), radix: 16)) \($0.count)\($0.isTarget ? " *" : "")" }
        // Both shortest paths go through r → c (y is as near to s, the tie goes to the first found).
        XCTAssertEqual(lines.first, "0 1000 \(merged.first!.count)")
        XCTAssertTrue(lines.contains("2 5000 1 *"), lines.joined(separator: "\n"))
        XCTAssertEqual(merged.filter(\.isTarget).count, 2)
    }

    func testDeepPathsDoNotRecurse() async throws {
        // A 20,000-object chain from one root: its path and its merged path are 20,000 deep, and
        // building or releasing them must not use a stack frame per level.
        var graph = GraphDump()
        let count = 20_000
        for position in 0..<count {
            let id = UInt64(0x10_0000 + position * 0x40)
            graph.node(id, position + 1 < count ? [UInt64(0x10_0000 + (position + 1) * 0x40)] : [])
        }
        graph.roots = [0x10_0000]
        let index = try await build(graph.writer(), name: "chain")
        let last = try XCTUnwrap(index.number(ofID: UInt64(0x10_0000 + (count - 1) * 0x40)))
        let lines = await Task.detached { () -> Int in
            let merged = index.mergedPathsToRoots(of: [last], limit: 50_000)
            return merged.count
        }.value
        XCTAssertEqual(lines, count)
        XCTAssertEqual(index.pathToRoot(of: last).count, count)
        XCTAssertEqual(index.retainedSize(of: try XCTUnwrap(index.number(ofID: 0x10_0000))), index.reachableBytes)
    }

    // MARK: - Against brute force

    func testRandomGraphsMatchNaiveDominatorsAndRetainedSizes() async throws {
        var random = SeededRandom(seed: 0xD0D0)
        for round in 0..<300 {
            let count = 2 + Int(random.next() % 40)
            let ids = (0..<count).map { UInt64(0x10000 + $0 * 0x100) }
            var graph = GraphDump()
            for id in ids {
                let degree = Int(random.next() % 4)
                graph.node(id, (0..<degree).map { _ in ids[Int(random.next() % UInt64(count))] })
            }
            graph.roots = (0..<(1 + Int(random.next() % 3))).map { _ in ids[Int(random.next() % UInt64(count))] }
            let index = try await build(graph.writer(), name: "random-\(round)")

            // Naive: reachability, dominator sets by iteration, retained by removal.
            let s: UInt64 = 0
            var successors = graph.edges
            successors[s] = Array(Set(graph.roots))
            func reachable(without removed: UInt64?) -> Set<UInt64> {
                var seen: Set<UInt64> = [s]
                var queue = [s]
                while let v = queue.popLast() {
                    for w in successors[v] ?? [] where w != removed && seen.insert(w).inserted { queue.append(w) }
                }
                return seen
            }
            let all = reachable(without: nil)
            var predecessors: [UInt64: [UInt64]] = [:]
            for (v, list) in successors where all.contains(v) { for w in list { predecessors[w, default: []].append(v) } }
            var dom: [UInt64: Set<UInt64>] = [:]
            for v in all { dom[v] = v == s ? [s] : all }
            var changed = true
            while changed {
                changed = false
                for v in all where v != s {
                    let preds = (predecessors[v] ?? []).filter { all.contains($0) }
                    var next = preds.map { dom[$0]! }.reduce(all) { $0.intersection($1) }
                    next.insert(v)
                    if next != dom[v] { dom[v] = next; changed = true }
                }
            }
            for id in ids {
                let n = try XCTUnwrap(index.number(ofID: id))
                guard all.contains(id) else {
                    XCTAssertNil(index.dominator(of: n), "round \(round): \(id) unreachable")
                    XCTAssertEqual(index.retainedSize(of: n), 0)
                    continue
                }
                let strict = dom[id]!.subtracting([id])
                let idom = strict.max { dom[$0]!.count < dom[$1]!.count }!
                let found = index.dominator(of: n).map { $0 == 0 ? 0 : index.id(of: $0) }
                XCTAssertEqual(found, idom, "round \(round): idom of \(String(id, radix: 16))")
                let freed = all.subtracting(reachable(without: id))
                let bytes = freed.reduce(Int64(0)) { $0 + GraphDump.size(graph.edges[$1]?.count ?? 0) }
                XCTAssertEqual(index.retainedSize(of: n), bytes, "round \(round): retained of \(String(id, radix: 16))")
                // The path is a real chain of references, as short as any.
                let path = index.pathToRoot(of: n).map { index.id(of: $0) }
                XCTAssertTrue(graph.roots.contains(path.last!))
                for (child, parent) in zip(path, path.dropFirst()) {
                    XCTAssertTrue(graph.edges[parent]!.contains(child), "round \(round): \(parent) → \(child)")
                }
                var distance: [UInt64: Int] = [:]
                var queue = Array(Set(graph.roots))
                for r in queue { distance[r] = 0 }
                var head = 0
                while head < queue.count {
                    let v = queue[head]; head += 1
                    for w in graph.edges[v] ?? [] where distance[w] == nil { distance[w] = distance[v]! + 1; queue.append(w) }
                }
                XCTAssertEqual(path.count - 1, distance[id], "round \(round): shortest path of \(String(id, radix: 16))")
            }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("random-\(round)-index"))
        }
    }
}

private extension Int {
    var asInt32: Int32 { Int32(self) }
}
