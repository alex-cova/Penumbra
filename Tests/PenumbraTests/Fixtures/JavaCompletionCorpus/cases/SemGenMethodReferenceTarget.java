//! contains: toUpperCase
//! excludes: nonexistent
package com.acme.cases;
import java.util.*;
class SemGenMethodReferenceTarget {
    void test(List<String> names) {
        names.stream().map(String::toUp/*|*/);
    }
}
