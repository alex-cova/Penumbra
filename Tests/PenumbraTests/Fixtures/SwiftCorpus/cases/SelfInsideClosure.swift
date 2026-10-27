final class Loader {
    var items: [Int] = []
    func load() { run { [self] in self./*|*/ } }
    func run(_ f: () -> Void) {}
}
//! contains: items, load
//! gap: self-member
