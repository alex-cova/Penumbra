enum Outcome { case ok(Int), fail }
extension Outcome { var isOK: Bool { true } }
let r = Outcome.ok(1)
r./*|*/
//! contains: isOK
