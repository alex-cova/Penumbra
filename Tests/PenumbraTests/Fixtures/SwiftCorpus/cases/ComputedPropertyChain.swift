struct Inner { var depth = 0 }
struct Box { var inner: Inner { Inner() } }
Box().inner./*|*/
//! contains: depth
