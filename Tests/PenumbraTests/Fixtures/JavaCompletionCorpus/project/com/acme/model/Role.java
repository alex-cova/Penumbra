package com.acme.model;

public enum Role {
    ADMIN, EDITOR, VIEWER;

    public boolean canWrite() { return this != VIEWER; }
}
