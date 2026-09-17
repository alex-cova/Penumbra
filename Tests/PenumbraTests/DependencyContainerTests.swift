import XCTest
import EditorIntelligence

final class DependencyContainerTests: XCTestCase {
    func testRegisterAndResolve() {
        let container = DependencyContainer()
        container.register(String.self) { "hello" }
        XCTAssertEqual(container.resolve(String.self), "hello")
    }

    func testSingleton() {
        let container = DependencyContainer()
        let value = Counter()
        container.registerSingleton(value)
        XCTAssertTrue(container.resolve(Counter.self) === value)
    }

    func testFactoryCreatesNewInstance() {
        let container = DependencyContainer()
        container.register(Counter.self) { Counter() }
        let first = container.resolve(Counter.self)
        let second = container.resolve(Counter.self)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertTrue(first !== second)
    }

    func testResolveRequiredThrowsWhenMissing() {
        let container = DependencyContainer()
        XCTAssertThrowsError(try container.resolveRequired(String.self)) { error in
            guard case DependencyError.missing(let type) = error else {
                return XCTFail("Expected missing dependency error")
            }
            XCTAssertEqual(type, "String")
        }
    }
}

private final class Counter {}
