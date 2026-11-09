import Darwin
import Foundation

/// Counts and attributes the heap allocations made between `start()` and `stop()`, through libmalloc's
/// `malloc_logger` hook (the one MallocStackLogging uses). It is for the release harness only: the
/// hook is a plain global in libsystem_malloc, nothing here is linked into Umbra.
///
/// What it reports:
/// - every allocation's size, summed (`totalBytes`, `totalCount`) and the part in allocations of
///   4 KB or more;
/// - each allocation of `largeThreshold` or more, with the code that made it (return addresses taken
///   with `backtrace`, symbolicated and demangled afterwards), which is how a whole-document copy shows
///   up as a line with the document's size on it;
/// - the peak of large allocations alive at once, which is the temporary memory a request needs.
///
/// The hook runs inside `malloc` and must not allocate, so everything it touches is fixed storage
/// created before it is installed.
enum AllocationTrace {
    struct Large {
        let size: Int
        let frames: [UInt]
    }

    struct Report {
        var totalBytes = 0
        var totalCount = 0
        var bytesInAllocationsOfAtLeast4K = 0
        var peakLiveLargeBytes = 0
        var large: [Large] = []
    }

    private static let frameDepth = 28
    private static let largeCapacity = 512
    private static let liveCapacity = 256

    private typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    private struct State {
        var enabled = false
        var threshold = 64 * 1024
        var totalBytes = 0
        var totalCount = 0
        var bytes4K = 0
        var largeCount = 0
        var liveCount = 0
        var liveBytes = 0
        var peakLiveBytes = 0
    }

    // All of this is allocated before the hook is installed and never resized.
    nonisolated(unsafe) private static let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
        return pointer
    }()
    nonisolated(unsafe) private static let state = UnsafeMutablePointer<State>.allocate(capacity: 1)
    nonisolated(unsafe) private static let largeSizes = UnsafeMutablePointer<Int>.allocate(capacity: largeCapacity)
    nonisolated(unsafe) private static let largeFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: largeCapacity * frameDepth)
    nonisolated(unsafe) private static let largeFrameCounts = UnsafeMutablePointer<Int>.allocate(capacity: largeCapacity)
    nonisolated(unsafe) private static let livePointers = UnsafeMutablePointer<UInt>.allocate(capacity: liveCapacity)
    nonisolated(unsafe) private static let liveSizes = UnsafeMutablePointer<Int>.allocate(capacity: liveCapacity)

    private static let hook: Logger = { type, arg1, arg2, arg3, result, _ in
        guard AllocationTrace.state.pointee.enabled else { return }
        let isAllocation = type & 2 != 0
        let isDeallocation = type & 4 != 0
        os_unfair_lock_lock(AllocationTrace.lock)
        defer { os_unfair_lock_unlock(AllocationTrace.lock) }
        if isAllocation && isDeallocation {
            // realloc(zone, old, newSize) -> result
            AllocationTrace.noteFree(pointer: arg2)
            AllocationTrace.noteAllocation(size: Int(arg3), pointer: result)
        } else if isAllocation {
            AllocationTrace.noteAllocation(size: Int(arg2), pointer: result)
        } else if isDeallocation {
            AllocationTrace.noteFree(pointer: arg2)
        }
    }

    private static func noteAllocation(size: Int, pointer: UInt) {
        let state = AllocationTrace.state
        state.pointee.totalBytes &+= size
        state.pointee.totalCount &+= 1
        if size >= 4096 { state.pointee.bytes4K &+= size }
        guard size >= state.pointee.threshold else { return }
        let index = state.pointee.largeCount
        if index < largeCapacity {
            largeSizes[index] = size
            let frames = largeFrames + index * frameDepth
            largeFrameCounts[index] = Int(backtrace(frames, Int32(frameDepth)))
            state.pointee.largeCount = index + 1
        }
        let live = state.pointee.liveCount
        if live < liveCapacity {
            livePointers[live] = pointer
            liveSizes[live] = size
            state.pointee.liveCount = live + 1
            state.pointee.liveBytes &+= size
            state.pointee.peakLiveBytes = max(state.pointee.peakLiveBytes, state.pointee.liveBytes)
        }
    }

    private static func noteFree(pointer: UInt) {
        let state = AllocationTrace.state
        var index = state.pointee.liveCount - 1
        while index >= 0 {
            if livePointers[index] == pointer {
                state.pointee.liveBytes -= liveSizes[index]
                let last = state.pointee.liveCount - 1
                livePointers[index] = livePointers[last]
                liveSizes[index] = liveSizes[last]
                state.pointee.liveCount = last
                return
            }
            index -= 1
        }
    }

    private static func slot() -> UnsafeMutablePointer<Logger?>? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        return symbol.assumingMemoryBound(to: Logger?.self)
    }

    /// Starts counting. `largeThreshold` is the size from which an allocation is kept with its call stack.
    static func start(largeThreshold: Int = 64 * 1024) {
        // Swift initializes a static on first use. That must not happen inside the hook, where its
        // allocation would re-enter the hook, so every static is touched here first.
        _ = (lock, state, largeSizes, largeFrames, largeFrameCounts, livePointers, liveSizes, hook, frameDepth)
        state.initialize(to: State())
        state.pointee.threshold = largeThreshold
        slot()?.pointee = hook
        state.pointee.enabled = true
    }

    static func stop() -> Report {
        state.pointee.enabled = false
        slot()?.pointee = nil
        var report = Report()
        report.totalBytes = state.pointee.totalBytes
        report.totalCount = state.pointee.totalCount
        report.bytesInAllocationsOfAtLeast4K = state.pointee.bytes4K
        report.peakLiveLargeBytes = state.pointee.peakLiveBytes
        for index in 0..<state.pointee.largeCount {
            let frames = (0..<largeFrameCounts[index]).map { UInt(bitPattern: largeFrames[index * frameDepth + $0]) }
            report.large.append(Large(size: largeSizes[index], frames: frames))
        }
        return report
    }

    // MARK: - Symbolication

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    private static let internalPrefixes = [
        "malloc", "_malloc", "calloc", "_calloc", "realloc", "_realloc", "szone", "nano", "_nano", "tiny_", "small_", "large_",
        "default_zone", "free", "_free", "AllocationTrace", "$s12PerfHarness15AllocationTrace", "swift_slowAlloc", "swift_allocObject",
        "_swift_allocObject", "$ss13_StringObject", "posix_memalign", "_platform_", "mvm_", "__"
    ]

    /// Readable names for `frames`, innermost first, with the allocator's and the tracer's own frames
    /// dropped: the first few frames (what allocated: a `String` initializer, `Array.init`...) and then
    /// the first frame that belongs to Umbra's own modules, which is the code to look at.
    static func describe(_ frames: [UInt], limit: Int = 4) -> [String] {
        let demangle: Demangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle").map { unsafeBitCast($0, to: Demangle.self) }
        let ours = ["JavaIntelligence.", "LanguageSyntax.", "EditorIntelligence.", "PerfHarness."]
        var names: [String] = []
        var foundOurs = false
        for address in frames {
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let symbol = info.dli_sname else { continue }
            let mangled = String(cString: symbol)
            if internalPrefixes.contains(where: { mangled.hasPrefix($0) }) || mangled.hasPrefix("_ZN5swift") { continue }
            var readable = mangled
            if let demangle, let cString = demangle(symbol, strlen(symbol), nil, nil, 0) {
                readable = String(cString: cString)
                free(cString)
            }
            if readable.contains("AllocationTrace") { continue }
            // Drop the compiler's decoration and the argument list; keep the function's name.
            for marker in ["function signature specialization ", "generic specialization ", "merged "] {
                while let range = readable.range(of: marker), let end = readable.range(of: " of ", range: range.upperBound..<readable.endIndex) {
                    readable.removeSubrange(range.lowerBound..<end.upperBound)
                }
            }
            if let paren = readable.firstIndex(of: "(") { readable = String(readable[..<paren]) }
            let isOurs = ours.contains { readable.contains($0) }
            if names.count < limit {
                names.append(readable)
                foundOurs = foundOurs || isOurs
            } else if isOurs, !foundOurs {
                names.append("… " + readable)
                break
            }
            if names.count >= limit, foundOurs { break }
        }
        return names
    }
}
