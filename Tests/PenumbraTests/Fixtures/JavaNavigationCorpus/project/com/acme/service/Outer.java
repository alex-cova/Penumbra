package com.acme.service;

public class Outer {
    public static int count;

    public static class Inner {
        public int depth;

        public Inner() {}
    }

    public Inner make() {
        return new Inner();
    }
}
