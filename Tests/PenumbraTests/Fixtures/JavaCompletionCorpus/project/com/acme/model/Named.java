package com.acme.model;

public interface Named {
    String getName();

    default String displayName() { return getName(); }
}
