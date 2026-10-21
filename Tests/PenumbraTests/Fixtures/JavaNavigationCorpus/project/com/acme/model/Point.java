package com.acme.model;

public record Point(int x, int y) {
    public Point {
        if (x < 0) throw new IllegalArgumentException();
    }

    public double dist() {
        return Math.sqrt(x * x + y * y);
    }
}
