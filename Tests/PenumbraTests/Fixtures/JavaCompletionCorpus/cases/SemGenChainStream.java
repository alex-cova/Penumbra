//! contains: toUpperCase
package com.acme.cases;
import java.util.*;
import java.util.stream.*;
class SemGenChainStream {
    void test(List<String> names) {
        names.stream().map(String::trim).filter(s -> !s.isEmpty()).findFirst().get().toUp/*|*/
    }
}
