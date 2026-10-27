struct Outer { struct Inner { static let id = 1 } }
Outer.Inner./*|*/
//! contains: id
