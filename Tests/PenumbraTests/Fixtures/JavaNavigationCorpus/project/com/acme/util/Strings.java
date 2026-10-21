package com.acme.util;

public final class Strings {
    public static final String EMPTY = "";

    private Strings() {}

    public static boolean isBlank(String s) {
        return s == null || s.isEmpty();
    }

    public static String join(String a, String b) {
        return a + b;
    }

    public static String join(String a, String b, String c) {
        return a + b + c;
    }

    public static String repeat(String s, int times) {
        return s.repeat(times);
    }

    public static String repeat(char c, int times) {
        return String.valueOf(c).repeat(times);
    }
}
