struct Point {
    var x: Int
    static let zero = Point(x: 0)
    func moved() -> Point { self }
}
extension Point {
    func length() -> Double { 0 }
}
let p = Point(x: 1)
p./*|*/
//! contains: x, moved, length
//! excludes: zero, if
