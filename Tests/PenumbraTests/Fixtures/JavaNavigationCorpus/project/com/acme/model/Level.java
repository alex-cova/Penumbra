package com.acme.model;

public enum Level {
    LOW("low", 1),
    HIGH("high", 9);

    private final String label;
    private final int weight;

    Level(String label, int weight) {
        this.label = label;
        this.weight = weight;
    }

    public String label() {
        return label;
    }

    public int weight() {
        return weight;
    }

    public static Level parse(String text) {
        return valueOf(text.toUpperCase());
    }
}
