//! contains: toUpperCase
package com.acme.cases;
import java.util.*;
class SemGenGenericMethodInference {
    static <T> T first(List<T> l) { return l.get(0); }
    void test(List<String> names) {
        first(names).toUp/*|*/
    }
}
