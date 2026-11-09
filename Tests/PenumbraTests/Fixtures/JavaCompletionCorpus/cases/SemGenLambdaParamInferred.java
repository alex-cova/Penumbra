//! contains: toUpperCase
package com.acme.cases;
import java.util.*;
import java.util.function.*;
class SemGenLambdaParamInferred {
    void test(List<String> names) {
        names.forEach(n -> n.toUp/*|*/);
    }
}
