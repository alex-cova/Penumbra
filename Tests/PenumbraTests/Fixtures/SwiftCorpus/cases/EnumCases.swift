enum Color {
    case red, green
    static let brand = Color.red
    var name: String { "" }
}
let c = Color./*|*/
//! contains: red, green, brand
//! excludes: name
