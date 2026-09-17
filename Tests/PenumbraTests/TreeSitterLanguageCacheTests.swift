import XCTest
import TestTreeSitterLanguages
@testable import Penumbra

final class TreeSitterLanguageCacheTests: XCTestCase {
    private enum Key: Hashable {
        case json
        case unsupported
    }

    func testRepeatedCallsReturnTheSameInstanceWithoutCallingMakeAgain() {
        let cache = TreeSitterLanguageCache<Key>()
        var makeCallCount = 0
        let make = {
            makeCallCount += 1
            return TreeSitterLanguage(tree_sitter_json())
        }

        let first = cache.language(for: .json, make: make)
        let second = cache.language(for: .json, make: make)

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
        XCTAssertEqual(makeCallCount, 1)
    }

    func testNilFactoryResultIsNotCachedAndIsRetriedOnNextCall() {
        let cache = TreeSitterLanguageCache<Key>()
        var makeCallCount = 0

        let first = cache.language(for: .unsupported) {
            makeCallCount += 1
            return nil
        }
        let second = cache.language(for: .unsupported) {
            makeCallCount += 1
            return nil
        }

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(makeCallCount, 2)
    }

    func testResetClearsTheCacheSoMakeIsCalledAgain() {
        let cache = TreeSitterLanguageCache<Key>()
        var makeCallCount = 0
        let make = {
            makeCallCount += 1
            return TreeSitterLanguage(tree_sitter_json())
        }

        _ = cache.language(for: .json, make: make)
        cache.reset()
        _ = cache.language(for: .json, make: make)

        XCTAssertEqual(makeCallCount, 2)
    }
}
