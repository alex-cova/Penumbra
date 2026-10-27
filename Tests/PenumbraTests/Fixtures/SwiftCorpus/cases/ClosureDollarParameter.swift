struct P { var age = 0 }
let people = [P()]
let ages = people.map { $0./*|*/ }
//! contains: age
//! gap: generics
