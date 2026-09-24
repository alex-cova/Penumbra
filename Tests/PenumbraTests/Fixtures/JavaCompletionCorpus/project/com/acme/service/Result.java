package com.acme.service;

public class Result<T> {
    public T get() { return null; }
    public boolean isOk() { return true; }
    public <R> Result<R> map(java.util.function.Function<? super T, ? extends R> mapper) { return null; }
    public static <T> Result<T> ok(T value) { return null; }
    public static <T> Result<T> empty() { return null; }
}
