import XCTest
import EditorIntelligence

final class EventBusTests: XCTestCase {
    func testSendEventDeliveredToSubscriber() async throws {
        let bus = EventBus<String>()
        let task = Task {
            var values: [String] = []
            for await value in bus.events {
                values.append(value)
                if values.count == 2 {
                    return values
                }
            }
            return values
        }
        // Give the subscriber a moment to start.
        try await Task.sleep(nanoseconds: 10_000_000)
        bus.send("hello")
        bus.send("world")
        let values = await task.value
        XCTAssertEqual(values, ["hello", "world"])
    }

    func testMultipleSubscribersReceiveEvents() async throws {
        let bus = EventBus<Int>()
        let task1 = Task {
            var sum = 0
            for await value in bus.events {
                sum += value
                if sum >= 3 {
                    return sum
                }
            }
            return sum
        }
        let task2 = Task {
            var sum = 0
            for await value in bus.events {
                sum += value
                if sum >= 3 {
                    return sum
                }
            }
            return sum
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        bus.send(1)
        bus.send(2)
        let value1 = await task1.value
        let value2 = await task2.value
        XCTAssertEqual(value1, 3)
        XCTAssertEqual(value2, 3)
    }
}
