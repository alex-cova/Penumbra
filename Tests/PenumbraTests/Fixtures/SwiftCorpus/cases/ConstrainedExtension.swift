struct Wrapper<T> { var value: T }
extension Wrapper where T == Int { func doubled() -> Int { value * 2 } }
let w = Wrapper(value: 1)
w./*|*/
//! contains: value, doubled
