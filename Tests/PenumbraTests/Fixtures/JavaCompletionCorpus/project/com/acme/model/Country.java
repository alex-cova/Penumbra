package com.acme.model;

public record Country(String code, String name) {
    public boolean isEu() { return false; }
}
