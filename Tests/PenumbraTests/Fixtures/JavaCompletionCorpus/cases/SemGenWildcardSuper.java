//! contains: add
package com.acme.cases;
import java.util.*;
class SemGenWildcardSuper {
    void test(List<? super Integer> sink) {
        sink.ad/*|*/
    }
}
