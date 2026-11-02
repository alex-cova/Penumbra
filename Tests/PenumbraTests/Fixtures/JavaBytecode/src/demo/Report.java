package demo;

import java.util.List;
import java.util.function.Supplier;

public class Report {
    public double total(List<Shape> shapes) {
        double sum = 0;
        for (Shape shape : shapes) {
            sum += shape.area();
        }
        return sum;
    }

    public double circle() {
        return new Circle(2).area();
    }

    public Supplier<Double> lazy(Square square) {
        return () -> square.area();
    }

    public Supplier<Double> reference(Circle circle) {
        return circle::area;
    }

    public String names(Square square) {
        return square.describe("x") + Square.created;
    }
}
