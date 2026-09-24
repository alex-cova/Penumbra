package com.umbra.debug;

import java.util.*;

final class Json {
    private Json() {}

    static Map<String, Object> parseObject(String text) {
        return parseObject(text, new Parser(text));
    }

    static String stringify(Object value) {
        StringBuilder out = new StringBuilder();
        write(out, value);
        return out.toString();
    }

    private static void write(StringBuilder out, Object value) {
        if (value == null) {
            out.append("null");
        } else if (value instanceof String s) {
            out.append('"');
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                switch (c) {
                    case '\\' -> out.append("\\\\");
                    case '"' -> out.append("\\\"");
                    case '\n' -> out.append("\\n");
                    case '\r' -> out.append("\\r");
                    case '\t' -> out.append("\\t");
                    default -> out.append(c);
                }
            }
            out.append('"');
        } else if (value instanceof Number || value instanceof Boolean) {
            out.append(value);
        } else if (value instanceof Map<?, ?> map) {
            out.append('{');
            boolean first = true;
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                if (!first) out.append(',');
                first = false;
                write(out, String.valueOf(entry.getKey()));
                out.append(':');
                write(out, entry.getValue());
            }
            out.append('}');
        } else if (value instanceof Iterable<?> items) {
            out.append('[');
            boolean first = true;
            for (Object item : items) {
                if (!first) out.append(',');
                first = false;
                write(out, item);
            }
            out.append(']');
        } else {
            write(out, String.valueOf(value));
        }
    }

    private static Map<String, Object> parseObject(String text, Parser parser) {
        parser.expect('{');
        Map<String, Object> map = new LinkedHashMap<>();
        if (parser.peek('}')) {
            parser.expect('}');
            return map;
        }
        while (true) {
            String key = parser.readString();
            parser.expect(':');
            map.put(key, parser.readValue());
            if (parser.peek('}')) {
                parser.expect('}');
                break;
            }
            parser.expect(',');
        }
        return map;
    }

    private static final class Parser {
        private final String text;
        private int index;

        Parser(String text) { this.text = text; }

        Object readValue() {
            skipWhitespace();
            char c = text.charAt(index);
            if (c == '"') return readString();
            if (c == '{') return parseObject(text, this);
            if (c == '[') return readArray();
            if (c == 't' || c == 'f') return readBoolean();
            if (c == 'n') return readNull();
            return readNumber();
        }

        List<Object> readArray() {
            expect('[');
            List<Object> list = new ArrayList<>();
            if (peek(']')) { expect(']'); return list; }
            while (true) {
                list.add(readValue());
                if (peek(']')) { expect(']'); break; }
                expect(',');
            }
            return list;
        }

        String readString() {
            expect('"');
            StringBuilder out = new StringBuilder();
            while (index < text.length()) {
                char c = text.charAt(index++);
                if (c == '"') return out.toString();
                if (c == '\\') {
                    char next = text.charAt(index++);
                    switch (next) {
                        case '"', '\\', '/' -> out.append(next);
                        case 'n' -> out.append('\n');
                        case 'r' -> out.append('\r');
                        case 't' -> out.append('\t');
                        default -> out.append(next);
                    }
                } else {
                    out.append(c);
                }
            }
            throw new IllegalArgumentException("unterminated string");
        }

        Number readNumber() {
            int start = index;
            while (index < text.length()) {
                char c = text.charAt(index);
                if (Character.isDigit(c) || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E') {
                    index++;
                } else break;
            }
            String slice = text.substring(start, index);
            if (slice.contains(".") || slice.contains("e") || slice.contains("E")) {
                return Double.parseDouble(slice);
            }
            return Integer.parseInt(slice);
        }

        Boolean readBoolean() {
            if (text.startsWith("true", index)) { index += 4; return true; }
            if (text.startsWith("false", index)) { index += 5; return false; }
            throw new IllegalArgumentException("invalid boolean");
        }

        Object readNull() {
            if (text.startsWith("null", index)) { index += 4; return null; }
            throw new IllegalArgumentException("invalid null");
        }

        void expect(char c) {
            skipWhitespace();
            if (index >= text.length() || text.charAt(index) != c) {
                throw new IllegalArgumentException("expected '" + c + "'");
            }
            index++;
        }

        boolean peek(char c) {
            skipWhitespace();
            return index < text.length() && text.charAt(index) == c;
        }

        void skipWhitespace() {
            while (index < text.length() && Character.isWhitespace(text.charAt(index))) index++;
        }
    }
}
