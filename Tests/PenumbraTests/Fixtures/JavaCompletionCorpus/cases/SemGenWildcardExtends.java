//! contains: length
//! excludes: nonexistent
package com.acme.cases;
import java.util.*;
class SemGenWildcardExtends {
    void test(List<? extends CharSequence> items, Map<String, ? extends List<? extends Number>> m) {
        items.get(0).leng/*|*/
    }
}
