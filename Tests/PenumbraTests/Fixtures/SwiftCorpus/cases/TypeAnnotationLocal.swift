struct Item { var title = "" }
func f() {
    let item: Item = Item()
    item./*|*/
}
//! contains: title
