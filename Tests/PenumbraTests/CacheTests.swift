import XCTest
import EditorIntelligence

final class CacheTests: XCTestCase {
    func testGetAndSet() async {
        let cache = Cache<String, Int>()
        await cache.set(42, for: "answer")
        let value = await cache.get("answer")
        XCTAssertEqual(value, 42)
    }

    func testUpdateValue() async {
        let cache = Cache<String, Int>()
        await cache.set(1, for: "key")
        await cache.set(2, for: "key")
        let value = await cache.get("key")
        XCTAssertEqual(value, 2)
    }

    func testLRUEviction() async {
        let cache = Cache<String, Int>(maxSize: 2)
        await cache.set(1, for: "a")
        await cache.set(2, for: "b")
        await cache.set(3, for: "c")
        let a = await cache.get("a")
        let b = await cache.get("b")
        let c = await cache.get("c")
        XCTAssertNil(a)
        XCTAssertEqual(b, 2)
        XCTAssertEqual(c, 3)
    }

    func testAccessPromotesEntry() async {
        let cache = Cache<String, Int>(maxSize: 2)
        await cache.set(1, for: "a")
        await cache.set(2, for: "b")
        _ = await cache.get("a")
        await cache.set(3, for: "c")
        let a = await cache.get("a")
        let b = await cache.get("b")
        let c = await cache.get("c")
        XCTAssertEqual(a, 1)
        XCTAssertNil(b)
        XCTAssertEqual(c, 3)
    }
}
