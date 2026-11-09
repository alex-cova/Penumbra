//! contains: intValue
package com.acme.cases;
import java.util.*;
class SemGenOptionalMap {
    void test(Optional<String> s) {
        s.map(String::length).orElse(0).int/*|*/
    }
}
