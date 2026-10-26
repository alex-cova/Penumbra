package com.umbra.analysis;

import java.util.*;

/**
 * Minimal JSON reader/writer for the line protocol. Objects map to
 * {@code Map<String, Object>}, arrays to {@code List<Object>}, numbers to
 * {@code Long} or {@code Double}.
 */
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
                    default -> {
                        if (c < 0x20) out.append(String.format("\\u%04x", (int) c));
                        else out.append(c);
                    }
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
            if (index >= text.length()) throw new IllegalArgumentException("unexpected end of JSON");
            char c = text.charAt(index);
            if (c == '"') return readString();
            if (c == '{') return parseObject(text, this);
            if (c == '[') return readArray();
            if (c == 't' || c == 'f') return readBoolean();
            if (c == 'n') return readNull();
            return readNumber();
        }

        String readString() {
            expect('"');
            StringBuilder out = new StringBuilder();
            while (true) {
                if (index >= text.length()) throw new IllegalArgumentException("unterminated string");
                char c = text.charAt(index++);
                if (c == '"') return out.toString();
                if (c == '\\') {
                    if (index >= text.length()) throw new IllegalArgumentException("unterminated escape");
                    char e = text.charAt(index++);
                    switch (e) {
                        case '"' -> out.append('"');
                        case '\\' -> out.append('\\');
                        case '/' -> out.append('/');
                        case 'n' -> out.append('\n');
                        case 'r' -> out.append('\r');
                        case 't' -> out.append('\t');
                        case 'b' -> out.append('\b');
                        case 'f' -> out.append('\f');
                        case 'u' -> {
                            if (index + 4 > text.length()) throw new IllegalArgumentException("bad unicode escape");
                            out.append((char) Integer.parseInt(text.substring(index, index + 4), 16));
                            index += 4;
                        }
                        default -> throw new IllegalArgumentException("bad escape: \\" + e);
                    }
                } else {
                    out.append(c);
                }
            }
        }

        List<Object> readArray() {
            expect('[');
            List<Object> list = new ArrayList<>();
            skipWhitespace();
            if (peek(']')) {
                expect(']');
                return list;
            }
            while (true) {
                list.add(readValue());
                skipWhitespace();
                if (peek(']')) {
                    expect(']');
                    return list;
                }
                expect(',');
            }
        }

        Boolean readBoolean() {
            if (text.startsWith("true", index)) {
                index += 4;
                return Boolean.TRUE;
            }
            if (text.startsWith("false", index)) {
                index += 5;
                return Boolean.FALSE;
            }
            throw new IllegalArgumentException("bad literal at " + index);
        }

        Object readNull() {
            if (text.startsWith("null", index)) {
                index += 4;
                return null;
            }
            throw new IllegalArgumentException("bad literal at " + index);
        }

        Number readNumber() {
            int start = index;
            while (index < text.length() && "-+0123456789.eE".indexOf(text.charAt(index)) >= 0) index++;
            String token = text.substring(start, index);
            try {
                return Long.parseLong(token);
            } catch (NumberFormatException notLong) {
                return Double.parseDouble(token);
            }
        }

        void expect(char c) {
            skipWhitespace();
            if (index >= text.length() || text.charAt(index) != c) {
                throw new IllegalArgumentException("expected '" + c + "' at " + index);
            }
            index++;
        }

        boolean peek(char c) {
            skipWhitespace();
            return index < text.length() && text.charAt(index) == c;
        }

        void skipWhitespace() {
            while (index < text.length()) {
                char c = text.charAt(index);
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r') index++;
                else break;
            }
        }
    }
}
