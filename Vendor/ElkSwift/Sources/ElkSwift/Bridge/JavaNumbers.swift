import Foundation

package enum JavaNumbers {
    package static func intDiv(_ lhs: Int, _ rhs: Int) -> Int {
        lhs / rhs
    }

    package static func intMod(_ lhs: Int, _ rhs: Int) -> Int {
        lhs % rhs
    }

    package static func toInt(_ value: Double) -> Int {
        Int(value)
    }

    package static func toDouble(_ value: Int) -> Double {
        Double(value)
    }

    package static func isNaN(_ value: Double) -> Bool {
        value.isNaN
    }
}
