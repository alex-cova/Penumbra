package com.acme.model;

public abstract class Animal {
    protected String species;
    int legs;
    private int secretAge;

    public String getSpecies() { return species; }
    public abstract String sound();
    protected void breathe() { }
    void digest() { }

    public static class Entry {
        public String label() { return ""; }
        public int weight() { return 0; }
    }
}
