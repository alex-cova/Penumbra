package com.umbra.debug;

import java.util.List;
import java.util.Map;

final class JsonTest {
    public static void main(String[] args) {
        assertRoundTrip();
        System.out.println("JsonTest passed");
    }

    private static void assertRoundTrip() {
        Map<String, Object> parsed = Json.parseObject("""
            {"command":"launch","port":5005,"suspend":true,"args":["one","two"]}
            """);
        assert "launch".equals(parsed.get("command"));
        assert Integer.valueOf(5005).equals(parsed.get("port"));
        assert Boolean.TRUE.equals(parsed.get("suspend"));
        @SuppressWarnings("unchecked")
        List<Object> items = (List<Object>) parsed.get("args");
        assert items.size() == 2;
        assert "one".equals(items.get(0));
        assert "two".equals(items.get(1));

        String text = Json.stringify(Map.of("command", "resume", "frameIndex", 0));
        Map<String, Object> roundTrip = Json.parseObject(text);
        assert "resume".equals(roundTrip.get("command"));
        assert Integer.valueOf(0).equals(roundTrip.get("frameIndex"));
    }
}
