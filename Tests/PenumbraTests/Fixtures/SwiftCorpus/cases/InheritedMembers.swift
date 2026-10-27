class Animal { var legs = 4; func speak() {} }
class Dog: Animal { func fetch() {} }
let d = Dog()
d./*|*/
//! contains: legs, speak, fetch
