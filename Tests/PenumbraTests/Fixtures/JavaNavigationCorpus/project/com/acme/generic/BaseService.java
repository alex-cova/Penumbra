package com.acme.generic;

import java.util.List;

public abstract class BaseService<T> {
    protected T save(T entity) {
        return entity;
    }

    public List<T> all() {
        return List.of();
    }
}
