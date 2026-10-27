enum Outcome { case ok(Int), fail }
let r = Outcome./*|*/
//! contains: ok, fail
