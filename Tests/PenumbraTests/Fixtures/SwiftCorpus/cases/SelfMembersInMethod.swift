struct Counter {
    var count = 0
    mutating func bump() {
        self./*|*/
    }
}
//! contains: count, bump
//! gap: self-member
