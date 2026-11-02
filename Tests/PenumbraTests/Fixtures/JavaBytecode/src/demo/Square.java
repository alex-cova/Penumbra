package demo;

public class Square implements Shape {
    private final double side;
    public static int created;

    public Square(double side) {
        this.side = side;
        created++;
    }

    @Override
    public double area() {
        return side * side;
    }

    public String describe(String label, int times) {
        return label.repeat(times) + area();
    }

    public String describe(String label) {
        return describe(label, 1);
    }
}
