//! contains: length
package com.acme.cases;
import java.util.*;
import java.util.stream.*;
class SemGenLambdaCollectorsGrouping {
    void test(List<String> names) {
        Map<Integer, List<String>> byLen = names.stream().collect(Collectors.groupingBy(s -> s.len/*|*/));
    }
}
