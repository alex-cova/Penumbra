package com.acme.model;

public interface Named {
    String name();

    default String greeting() {
        return "hi " + name();
    }
}
