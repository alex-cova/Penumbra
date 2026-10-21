package com.acme.generic;

import java.util.function.Function;

public class Box<T> {
    private T value;

    public T get() {
        return value;
    }

    public <R> Box<R> map(Function<T, R> mapper) {
        return new Box<>();
    }
}
