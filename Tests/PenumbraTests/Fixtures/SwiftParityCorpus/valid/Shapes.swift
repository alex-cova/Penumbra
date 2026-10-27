enum Color {
    case red
    case green
    case blue
}

func name(of color: Color) -> String {
    switch color {
    case .red: return "red"
    case .green: return "green"
    case .blue: return "blue"
    }
}

protocol Shape {
    var area: Double { get }
}

struct Circle: Shape {
    var radius: Double

    var area: Double {
        return Double.pi * radius * radius
    }
}

struct Square: Shape {
    var side: Double

    var area: Double {
        return side * side
    }
}

func totalArea(of shapes: [Shape]) -> Double {
    var total = 0.0
    for shape in shapes {
        total += shape.area
    }
    return total
}
