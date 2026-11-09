//! contains: toUpperCase
package com.acme.cases;
import java.util.*;
class SemGenVarInference {
    void test(Map<String, String> m) {
        var e = m.entrySet().iterator().next();
        e.getValue().toUp/*|*/
    }
}
