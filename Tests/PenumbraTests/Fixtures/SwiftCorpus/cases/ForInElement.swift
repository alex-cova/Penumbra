struct Row { var id = 0 }
func f(rows: [Row]) {
    for row in rows {
        row./*|*/
    }
}
//! contains: id
