struct Pt { var x = 0 }
typealias Point = Pt
let p = Point()
p./*|*/
//! contains: x
