package com.acme.model;

public class Dog extends Animal implements Runnable {
    private String breed;

    public String getBreed() { return breed; }
    @Override
    public String sound() { return "woof"; }
    @Override
    public void run() { }
    public void fetch(String item) { }
    public void fetch(int times) { }
}
