//! contains: toUpperCase
package com.acme.cases;
import java.util.*;
class SemGenForEachVar {
    void test(Map<String, List<String>> m) {
        for (Map.Entry<String, List<String>> e : m.entrySet()) {
            e.getValue().get(0).toUp/*|*/
        }
    }
}
