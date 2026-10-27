struct Stack<T> { var items: [T] = []; mutating func push(_ x: T) {} }
var s = Stack<Int>()
s./*|*/
//! contains: items, push
