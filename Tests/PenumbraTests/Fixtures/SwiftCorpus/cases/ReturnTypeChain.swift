struct Engine { func rpm() -> Int { 0 } }
struct Car { func engine() -> Engine { Engine() } }
let c = Car()
c.engine()./*|*/
//! contains: rpm
