package com.example.parity;

public class Shapes {
    public interface Drawable {
        void draw();
    }

    public static class Circle implements Drawable {
        private double radius;

        public Circle(double radius) {
            this.radius = radius;
        }

        @Override
        public void draw() {
        }

        public double area() {
            return Math.PI * radius * radius;
        }
    }

    public enum Color {
        RED, GREEN, BLUE
    }

    public String describe(Color color) {
        switch (color) {
            case RED:
                return "red";
            case GREEN:
                return "green";
            case BLUE:
                return "blue";
        }
        throw new IllegalArgumentException("unknown color");
    }
}
