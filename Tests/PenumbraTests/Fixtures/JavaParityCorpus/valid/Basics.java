package com.example.parity;

import java.util.ArrayList;
import java.util.List;

public class Basics {
    private List<String> items = new ArrayList<>();

    public int count() {
        return items.size();
    }

    public String join(String separator) {
        String result = "";
        for (String item : items) {
            result = result + separator + item;
        }
        return result;
    }

    public void addAll(List<String> more) {
        items.addAll(more);
    }

    public String repeat(String text, int times) {
        String result = "";
        for (int i = 0; i < times; i++) {
            result = result + text;
        }
        return result;
    }

    public String twice(String text) {
        return repeat(text, 2);
    }

    public int parseOrDefault(String text, int fallback) {
        try {
            return Integer.parseInt(text);
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    public void save(java.io.OutputStream out) throws java.io.IOException {
        out.write(1);
    }
}
