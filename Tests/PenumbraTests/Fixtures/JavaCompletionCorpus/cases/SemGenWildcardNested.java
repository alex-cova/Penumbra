//! contains: intValue
//! excludes: length
package com.acme.cases;
import java.util.*;
class SemGenWildcardNested {
    void test(Map<String, ? extends List<? extends Number>> m) {
        m.get("a").get(0).int/*|*/
    }
}
