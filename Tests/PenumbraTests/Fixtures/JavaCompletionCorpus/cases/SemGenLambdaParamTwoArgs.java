//! contains: getValue
package com.acme.cases;
import java.util.*;
class SemGenLambdaParamTwoArgs {
    void test(Map<String, Integer> m) {
        m.entrySet().stream().sorted((a, b) -> a.getVal/*|*/
    }
}
