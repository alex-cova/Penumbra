import XCTest
@testable import Penumbra

@MainActor
final class EditorHostCacheTests: XCTestCase {
    private final class DummyHost {
        let id = UUID()
    }

    func testRetainsSameInstancePerKeyWithoutCallingMakeAgain() {
        let cache = EditorHostCache<UUID, DummyHost>()
        let key = UUID()
        var makeCallCount = 0
        let make = {
            makeCallCount += 1
            return DummyHost()
        }

        let first = cache.host(for: key, make: make)
        let second = cache.host(for: key, make: make)

        XCTAssertTrue(first === second)
        XCTAssertEqual(makeCallCount, 1)
    }

    func testRemoveDropsEntrySoMakeIsCalledAgain() {
        let cache = EditorHostCache<UUID, DummyHost>()
        let key = UUID()
        var makeCallCount = 0
        let make = {
            makeCallCount += 1
            return DummyHost()
        }

        _ = cache.host(for: key, make: make)
        cache.remove(key)
        _ = cache.host(for: key, make: make)

        XCTAssertEqual(makeCallCount, 2)
    }

    func testEvictsOldestWhenOverCapacity() {
        let cache = EditorHostCache<String, DummyHost>(maxEntries: 2)
        _ = cache.host(for: "a") { DummyHost() }
        _ = cache.host(for: "b") { DummyHost() }
        _ = cache.host(for: "c") { DummyHost() }

        XCTAssertFalse(cache.contains("a"), "Oldest-accessed entry should have been evicted")
        XCTAssertTrue(cache.contains("b"))
        XCTAssertTrue(cache.contains("c"))
    }

    func testAccessingAnEntryProtectsItFromEviction() {
        let cache = EditorHostCache<String, DummyHost>(maxEntries: 2)
        _ = cache.host(for: "a") { DummyHost() }
        _ = cache.host(for: "b") { DummyHost() }
        // Touch "a" again so it's the most recently accessed, then insert a third key.
        _ = cache.host(for: "a") { DummyHost() }
        _ = cache.host(for: "c") { DummyHost() }

        XCTAssertTrue(cache.contains("a"))
        XCTAssertFalse(cache.contains("b"), "Least-recently-accessed entry should have been evicted")
        XCTAssertTrue(cache.contains("c"))
    }

    func testRemoveAllClearsEveryEntry() {
        let cache = EditorHostCache<String, DummyHost>()
        _ = cache.host(for: "a") { DummyHost() }
        _ = cache.host(for: "b") { DummyHost() }
        cache.removeAll()
        XCTAssertFalse(cache.contains("a"))
        XCTAssertFalse(cache.contains("b"))
    }

    func testReconfigureEvictsDownToNewCapacity() {
        let cache = EditorHostCache<String, DummyHost>(maxEntries: 4)
        _ = cache.host(for: "a") { DummyHost() }
        _ = cache.host(for: "b") { DummyHost() }
        _ = cache.host(for: "c") { DummyHost() }
        cache.reconfigure(maxEntries: 1)

        let remaining = ["a", "b", "c"].filter { cache.contains($0) }
        XCTAssertEqual(remaining.count, 1, "Only the most recently accessed entry should remain")
        XCTAssertEqual(remaining.first, "c")
    }

    func testPeekReturnsNilOnMissWithoutCreatingAnEntry() {
        let cache = EditorHostCache<UUID, DummyHost>()
        let key = UUID()
        XCTAssertNil(cache.peek(key))
        XCTAssertFalse(cache.contains(key), "peek must not create an entry on a miss")
    }

    func testPeekReturnsTheCachedHostOnAHit() {
        let cache = EditorHostCache<UUID, DummyHost>()
        let key = UUID()
        let host = cache.host(for: key) { DummyHost() }
        XCTAssertTrue(cache.peek(key) === host)
    }

    func testPeekDoesNotAffectLRUOrder() {
        let cache = EditorHostCache<String, DummyHost>(maxEntries: 2)
        _ = cache.host(for: "a") { DummyHost() }
        _ = cache.host(for: "b") { DummyHost() }
        // Peeking "a" should not protect it from eviction the way `host(for:)` would.
        _ = cache.peek("a")
        _ = cache.host(for: "c") { DummyHost() }

        XCTAssertFalse(cache.contains("a"), "peek must not count as an access for LRU purposes")
        XCTAssertTrue(cache.contains("b"))
        XCTAssertTrue(cache.contains("c"))
    }
}
