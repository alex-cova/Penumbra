// Reference-type wrapper for [Int] to match Java's int[] reference semantics.
// In Java, int[] is a reference type shared across objects. In Swift, [Int] is
// a value type that gets copied on assignment. This wrapper ensures multiple
// CrossingsCounter instances share the same port positions array, matching Java behavior.
import Foundation

package final class SharedIntArray {
    package var values: [Int]

    package init() {
        self.values = []
    }

    package init(repeating value: Int, count: Int) {
        self.values = Array(repeating: value, count: count)
    }

    package subscript(index: Int) -> Int {
        get { values[index] }
        set { values[index] = newValue }
    }

    package var count: Int { values.count }
}
