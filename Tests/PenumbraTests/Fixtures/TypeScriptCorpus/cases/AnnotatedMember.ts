interface Foo { bar: string }
const x: Foo
x./*|*/
//! contains: bar
