extension String { func shout() -> String { uppercased() } }
let s = "a"
s./*|*/
//! contains: shout, count
