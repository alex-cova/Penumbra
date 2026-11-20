import Foundation

/// Shallow sizes of index objects under one layout: the instance shape of each class (its whole
/// chain), arrays by length, a class mirror as a `java.lang.Class` with the class's statics.
struct HeapShallowSizes: Sendable {
    let layout: HeapObjectLayout
    private let instance: [Int]
    private let mirror: [Int]
    private let elementSize: [Int]

    init(classes: [HeapClass], layout: HeapObjectLayout) {
        self.layout = layout
        var shapes: [(primitive: Int, references: Int)] = []
        shapes.reserveCapacity(classes.count)
        for index in classes.indices {
            var primitive = 0
            var references = 0
            var cursor = Int32(index)
            var seen = Set<Int32>()
            while cursor >= 0, Int(cursor) < classes.count, seen.insert(cursor).inserted {
                for field in classes[Int(cursor)].fields {
                    if field.type == .object { references += 1 } else { primitive += field.type.size(idSize: 8) }
                }
                cursor = classes[Int(cursor)].superIndex
            }
            shapes.append((primitive, references))
        }
        let classShape: (primitive: Int, references: Int) = classes.firstIndex { $0.name == "java.lang.Class" && $0.kind == .loaded }
            .map { shapes[$0] } ?? (primitive: 0, references: 0)
        instance = classes.indices.map { index in
            guard classes[index].kind == .loaded else { return -1 }
            return layout.instanceSize(primitiveBytes: shapes[index].primitive, references: shapes[index].references)
        }
        mirror = classes.map { entry in
            var primitive = classShape.primitive
            var references = classShape.references
            for field in entry.statics {
                if field.type == .object { references += 1 } else { primitive += field.type.size(idSize: 8) }
            }
            return layout.instanceSize(primitiveBytes: primitive, references: references)
        }
        elementSize = classes.map { entry in
            if case .primitiveArray(let type) = entry.kind { return type.size(idSize: 8) }
            return 0
        }
    }

    /// `length` is the array length, or for an instance the field bytes of its record (used only
    /// when its class is unknown).
    @inline(__always)
    func size(kind: UInt8, classIndex: Int32, length: UInt32) -> Int {
        let index = Int(classIndex)
        switch kind {
        case HeapObjectKind.instance.rawValue:
            if index > 0, index < instance.count, instance[index] >= 0 { return instance[index] }
            return HeapObjectLayout.align(layout.headerSize + Int(length))
        case HeapObjectKind.objectArray.rawValue:
            return layout.arraySize(length: Int(length), elementSize: layout.referenceSize)
        case HeapObjectKind.primitiveArray.rawValue:
            guard index >= 0, index < elementSize.count else { return 0 }
            return layout.arraySize(length: Int(length), elementSize: elementSize[index])
        case HeapObjectKind.classObject.rawValue:
            guard index >= 0, index < mirror.count else { return 0 }
            return mirror[index]
        default:
            return 0
        }
    }
}

/// Phase 3 of the index: who keeps whom alive. A dominator tree over the strong references (a
/// `Reference.referent` does not keep its object), rooted at the super-root (number 0) whose
/// children are the GC roots; retained sizes; each node's children sorted by retained size; a
/// class's retained size counting an instance only when no dominator above it has the same class;
/// the shortest strong path to a root for every object; what is unreachable, by class.
enum HeapDominatorBuilder {
    struct Facts: Sendable {
        let reachableCount: Int
        let reachableBytes: Int64
        let weaklyReachableCount: Int
        let weaklyReachableBytes: Int64
        let unreachableCount: Int
        let unreachableBytes: Int64
    }

    enum Files {
        static let dominators = "dominators.i32"
        static let retained = "retained.u64"
        static let childOffsets = "dom-offsets.u32"
        static let children = "dom-children.i32"
        static let pathParents = "path-parents.i32"
        static let classRetained = "class-retained.u64"
        static let unreachable = "unreachable.u64"
        static let weaklyReachable = "weakly-reachable.u64"
    }

    static func build(
        total: Int, roots: [Int32], outOffsets: HeapMappedArray<UInt32>, outTargets: HeapMappedArray<UInt32>,
        inOffsets: HeapMappedArray<UInt32>, inSources: HeapMappedArray<UInt32>,
        kinds: HeapMappedArray<UInt8>, classes: HeapMappedArray<Int32>, lengths: HeapMappedArray<UInt32>,
        sizes: HeapShallowSizes, groupCount: Int, mirrorGroup: Int32, directory: URL,
        progress: (Double) -> Void
    ) throws -> Facts {
        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
        func temp<T: BitwiseCopyable>(_ name: String, _ count: Int, _: T.Type) throws -> HeapMappedArray<T> {
            try HeapMappedArray<T>.create(url(name), count: count)
        }
        let weakBit = HeapIndexBuilder.weakBit
        var rootList = Array(Set(roots.filter { $0 > 0 && Int($0) < total })).sorted()
        if rootList.isEmpty, total > 1 {
            // A dump without root records: every object counts as one, so nothing is "unreachable".
            rootList = (1..<total).map(Int32.init)
        }
        let rootSet = Set(rootList)

        // 1. Depth-first preorder from the super-root over strong references.
        let pre = try temp("pre.tmp", total, Int32.self)              // vertex → preorder + 1 (0: not reached)
        let order = try temp("order.tmp", total, Int32.self)          // preorder → vertex
        let parent = try temp("parent.tmp", total, Int32.self)        // preorder → parent's preorder
        let stackVertex = try temp("stack-v.tmp", total, Int32.self)
        let stackCursor = try temp("stack-c.tmp", total, UInt32.self)
        defer {
            for name in ["pre.tmp", "order.tmp", "parent.tmp", "stack-v.tmp", "stack-c.tmp", "semi.tmp", "label.tmp", "ancestor.tmp", "idom-pre.tmp", "queue.tmp"] {
                try? FileManager.default.removeItem(at: url(name))
            }
        }
        var reached = 1
        pre[0] = 1
        order[0] = 0
        parent[0] = 0
        var depth = 1
        stackVertex[0] = 0
        stackCursor[0] = 0
        while depth > 0 {
            let v = Int(stackVertex[depth - 1])
            let cursor = Int(stackCursor[depth - 1])
            let count = v == 0 ? rootList.count : Int(outOffsets[v + 1] - outOffsets[v])
            guard cursor < count else {
                depth -= 1
                continue
            }
            stackCursor[depth - 1] = UInt32(cursor + 1)
            let w: Int
            if v == 0 {
                w = Int(rootList[cursor])
            } else {
                let stored = outTargets[Int(outOffsets[v]) + cursor]
                guard stored & weakBit == 0 else { continue }
                w = Int(stored)
            }
            guard pre[w] == 0 else { continue }
            pre[w] = Int32(reached + 1)
            order[reached] = Int32(w)
            parent[reached] = pre[v] - 1
            reached += 1
            stackVertex[depth] = Int32(w)
            stackCursor[depth] = 0
            depth += 1
            if reached & 0xFFFFF == 0 { try Task.checkCancellation() }
        }
        try? FileManager.default.removeItem(at: stackCursor.url)
        progress(0.25)

        // 2. Semi-dominators (simple Lengauer–Tarjan eval with path compression), then the
        //    nearest common ancestor step of semi-NCA. All indexes are preorder numbers.
        let semi = try temp("semi.tmp", reached, Int32.self)
        let label = try temp("label.tmp", reached, Int32.self)
        let ancestor = try temp("ancestor.tmp", reached, Int32.self)
        for k in 0..<reached {
            semi[k] = Int32(k)
            label[k] = Int32(k)
            ancestor[k] = -1
        }
        var path: [Int32] = []
        func eval(_ v: Int32) -> Int32 {
            guard ancestor[Int(v)] >= 0 else { return v }
            path.removeAll(keepingCapacity: true)
            var u = v
            while ancestor[Int(ancestor[Int(u)])] >= 0 {
                path.append(u)
                u = ancestor[Int(u)]
            }
            for x in path.reversed() {
                let a = ancestor[Int(x)]
                if semi[Int(label[Int(a)])] < semi[Int(label[Int(x)])] { label[Int(x)] = label[Int(a)] }
                ancestor[Int(x)] = ancestor[Int(a)]
            }
            return label[Int(v)]
        }
        for w in stride(from: reached - 1, to: 0, by: -1) {
            let vertex = Int(order[w])
            var best = semi[w]
            if rootSet.contains(Int32(vertex)) { best = 0 }
            let start = Int(inOffsets[vertex])
            let end = Int(inOffsets[vertex + 1])
            if start < end {
                for e in start..<end {
                    let stored = inSources[e]
                    guard stored & weakBit == 0 else { continue }
                    let u = pre[Int(stored)] - 1
                    guard u >= 0 else { continue }
                    let candidate = semi[Int(eval(u))]
                    if candidate < best { best = candidate }
                }
            }
            semi[w] = best
            ancestor[w] = parent[w]
            if w & 0xFFFFF == 0 { try Task.checkCancellation() }
        }
        try? FileManager.default.removeItem(at: label.url)
        try? FileManager.default.removeItem(at: ancestor.url)
        let idomPre = try temp("idom-pre.tmp", reached, Int32.self)
        idomPre[0] = 0
        for w in 1..<max(reached, 1) {
            var d = parent[w]
            while d > semi[w] { d = idomPre[Int(d)] }
            idomPre[w] = d
        }
        let dominators = try HeapMappedArray<Int32>.create(url(Files.dominators), count: total)
        for v in 0..<total { dominators[v] = -1 }
        for w in 1..<max(reached, 1) { dominators[Int(order[w])] = order[Int(idomPre[w])] }
        try Task.checkCancellation()
        progress(0.55)

        // 3. Retained sizes: children before parents, so reverse preorder.
        let retained = try HeapMappedArray<UInt64>.create(url(Files.retained), count: total)
        for w in stride(from: reached - 1, to: 0, by: -1) {
            let v = Int(order[w])
            retained[v] += UInt64(sizes.size(kind: kinds[v], classIndex: classes[v], length: lengths[v]))
            retained[Int(dominators[v])] += retained[v]
        }

        @inline(__always) func group(_ v: Int) -> Int {
            kinds[v] == HeapObjectKind.classObject.rawValue ? Int(mirrorGroup) : Int(classes[v])
        }
        progress(0.65)

        // 4. Each node's dominator children, largest retained first.
        let childOffsets = try HeapMappedArray<UInt32>.create(url(Files.childOffsets), count: total + 1)
        let children = try HeapMappedArray<Int32>.create(url(Files.children), count: max(reached - 1, 0))
        for w in 1..<max(reached, 1) { childOffsets[Int(dominators[Int(order[w])]) + 1] += 1 }
        for v in 0..<total { childOffsets[v + 1] += childOffsets[v] }
        let cursor = try temp("queue.tmp", total, UInt32.self)
        memcpy(UnsafeMutableRawPointer(cursor.base), UnsafeRawPointer(childOffsets.base), total * 4)
        for w in 1..<max(reached, 1) {
            let v = order[w]
            let d = Int(dominators[Int(v)])
            children[Int(cursor[d])] = v
            cursor[d] += 1
        }
        for v in 0..<total {
            let start = Int(childOffsets[v])
            let end = Int(childOffsets[v + 1])
            guard end - start > 1 else { continue }
            var slice = UnsafeMutableBufferPointer(rebasing: children.buffer[start..<end])
            slice.sort { a, b in
                let ra = retained[Int(a)], rb = retained[Int(b)]
                return ra != rb ? ra > rb : a < b
            }
        }
        try Task.checkCancellation()
        progress(0.8)

        // 5. Retained size by class: an object counts unless a dominator above it is of its class.
        let classRetained = try HeapMappedArray<UInt64>.create(url(Files.classRetained), count: max(groupCount, 1))
        var inside = [Int32](repeating: 0, count: groupCount)
        var stack: [(vertex: Int32, next: UInt32)] = [(0, childOffsets[0])]
        while let top = stack.last {
            let v = Int(top.vertex)
            if top.next < childOffsets[v + 1] {
                stack[stack.count - 1].next += 1
                let child = Int(children[Int(top.next)])
                let g = group(child)
                if g >= 0, g < groupCount {
                    if inside[g] == 0 { classRetained[g] += retained[child] }
                    inside[g] += 1
                }
                stack.append((Int32(child), childOffsets[child]))
            } else {
                stack.removeLast()
                if v != 0 {
                    let g = group(v)
                    if g >= 0, g < groupCount { inside[g] -= 1 }
                }
            }
        }
        progress(0.9)

        // 6. Shortest strong path to a root: the breadth-first parent of every object
        //    (0 for a root itself, -1 when unreachable).
        let parents = try HeapMappedArray<Int32>.create(url(Files.pathParents), count: total)
        for v in 0..<total { parents[v] = -1 }
        var head = 0
        var tail = 0
        for r in rootList where parents[Int(r)] == -1 {
            parents[Int(r)] = 0
            cursor[tail] = UInt32(r)
            tail += 1
        }
        while head < tail {
            let v = Int(cursor[head])
            head += 1
            let start = Int(outOffsets[v])
            let end = Int(outOffsets[v + 1])
            guard start < end else { continue }
            for e in start..<end {
                let stored = outTargets[e]
                guard stored & weakBit == 0 else { continue }
                let w = Int(stored)
                guard parents[w] == -1 else { continue }
                parents[w] = Int32(v)
                cursor[tail] = UInt32(w)
                tail += 1
            }
        }

        // 7. Only weakly reachable: what a root reaches once `Reference.referent` links count too.
        //    Such an object is not garbage yet (a soft-reference cache lives here), so it is kept
        //    apart from the unreachable. Its parent is stored as -(parent + 2); the strong
        //    breadth-first order seeds the search, so its path is short too.
        var weakTail = 0
        func reachWeakly(_ w: Int, from v: Int) {
            guard parents[w] == -1 else { return }
            parents[w] = -Int32(v) - 2
            stackVertex[weakTail] = Int32(w)
            weakTail += 1
        }
        for position in 0..<tail {
            let v = Int(cursor[position])
            let start = Int(outOffsets[v])
            let end = Int(outOffsets[v + 1])
            guard start < end else { continue }
            for e in start..<end where outTargets[e] & weakBit != 0 { reachWeakly(Int(outTargets[e] & ~weakBit), from: v) }
        }
        var weakHead = 0
        while weakHead < weakTail {
            let v = Int(stackVertex[weakHead])
            weakHead += 1
            let start = Int(outOffsets[v])
            let end = Int(outOffsets[v + 1])
            guard start < end else { continue }
            for e in start..<end { reachWeakly(Int(outTargets[e] & ~weakBit), from: v) }
        }

        // What is not strongly reachable, by group: only weakly reachable, or garbage.
        let unreachable = try HeapMappedArray<UInt64>.create(url(Files.unreachable), count: groupCount * 2)
        let weakly = try HeapMappedArray<UInt64>.create(url(Files.weaklyReachable), count: groupCount * 2)
        var unreachableCount = 0
        var unreachableBytes: Int64 = 0
        var weakCount = 0
        var weakBytes: Int64 = 0
        for v in 1..<max(total, 1) where parents[v] < 0 {
            let size = sizes.size(kind: kinds[v], classIndex: classes[v], length: lengths[v])
            let isWeak = parents[v] <= -2
            if isWeak {
                weakCount += 1
                weakBytes += Int64(size)
            } else {
                unreachableCount += 1
                unreachableBytes += Int64(size)
            }
            let g = group(v)
            guard g >= 0, g < groupCount else { continue }
            let table = isWeak ? weakly : unreachable
            table[2 * g] += 1
            table[2 * g + 1] += UInt64(size)
        }

        let written: [any HeapFlushable] = [dominators, retained, unreachable, weakly, childOffsets, children, classRetained, parents]
        for array in written { try array.flushToDisk() }
        progress(1)
        return Facts(
            reachableCount: reached - 1, reachableBytes: Int64(retained[0]),
            weaklyReachableCount: weakCount, weaklyReachableBytes: weakBytes,
            unreachableCount: unreachableCount, unreachableBytes: unreachableBytes
        )
    }
}
