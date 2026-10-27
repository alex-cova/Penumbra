protocol Shape { var area: Double { get }; func scaled(by factor: Double) -> Self }
func f(shape: any Shape) {
    shape./*|*/
}
//! contains: area, scaled
