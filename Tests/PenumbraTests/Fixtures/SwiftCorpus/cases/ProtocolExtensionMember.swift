protocol Greeter { var name: String { get } }
extension Greeter { func greet() -> String { "hi " + name } }
struct English: Greeter { var name = "x" }
let e = English()
e./*|*/
//! contains: name, greet
