package com.acme.util;

public final class Strings {
    private Strings() { }
    public static boolean isBlank(String value) { return value == null || value.isBlank(); }
    public static String capitalize(String value) { return value; }
    public static final String EMPTY = "";
}
