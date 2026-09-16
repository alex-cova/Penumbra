package struct Triple<F, S, T> {
    package let first: F
    package let second: S
    package let third: T

    package init(_ f: F, _ s: S, _ t: T) {
        first = f
        second = s
        third = t
    }

    package var getFirst: F {
        return first
    }

    package var getSecond: S {
        return second
    }

    package var getThird: T {
        return third
    }

    package func toString() -> String {
        return "(\(first), \(second), \(third))"
    }
}

extension Triple: Equatable where F: Equatable, S: Equatable, T: Equatable {
    package static func == (lhs: Triple, rhs: Triple) -> Bool {
        return lhs.first == rhs.first
            && lhs.second == rhs.second
            && lhs.third == rhs.third
    }
}

extension Triple: Hashable where F: Hashable, S: Hashable, T: Hashable {
    package func hash(into hasher: inout Hasher) {
        hasher.combine(first)
        hasher.combine(second)
        hasher.combine(third)
    }
}
