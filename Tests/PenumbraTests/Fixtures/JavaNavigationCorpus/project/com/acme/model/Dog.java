package com.acme.model;

public class Dog extends Animal implements Named {
    public Dog() {}

    public Dog(String name) {
        this.name = name;
    }

    @Override
    public String speak() {
        return "woof";
    }

    @Override
    public String name() {
        return name;
    }

    public void fetch(Ball ball) {}

    public void fetch(Ball ball, int times) {}

    public static Dog create() {
        return new Dog();
    }
}
