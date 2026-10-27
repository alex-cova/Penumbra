struct P { var age = 0 }
let people = [P()]
let adults = people.filter { person in person./*|*/ }
//! contains: age
//! gap: generics
