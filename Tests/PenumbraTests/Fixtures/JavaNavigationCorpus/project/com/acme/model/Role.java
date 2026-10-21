package com.acme.model;

public enum Role {
    ADMIN, USER;

    public boolean isAdmin() {
        return this == ADMIN;
    }
}
