package com.acme.model;

public abstract class Animal {
    protected String name;
    public static final int LEGS = 4;

    public abstract String speak();

    public String getName() {
        return name;
    }

    public void rename(String name) {
        this.name = name;
    }
}
