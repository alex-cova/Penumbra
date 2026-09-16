package struct UniqueTriple<F, S, T> {
    package let first: F
    package let second: S
    package let third: T

    package init(_ f: F, _ s: S, _ t: T) {
        self.first = f
        self.second = s
        self.third = t
    }

    package init(first: F, second: S, third: T) {
        self.first = first
        self.second = second
        self.third = third
    }

    package func getFirst() -> F {
        return first
    }

    package func getSecond() -> S {
        return second
    }

    package func getThird() -> T {
        return third
    }

    var description: String {
        return "(\(first), \(second), \(third))"
    }
}
