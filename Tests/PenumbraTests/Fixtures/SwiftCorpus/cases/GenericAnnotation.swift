struct Stack<T> { var items: [T] = [] }
func f(q: Stack<String>) {
    q./*|*/
}
//! contains: items
