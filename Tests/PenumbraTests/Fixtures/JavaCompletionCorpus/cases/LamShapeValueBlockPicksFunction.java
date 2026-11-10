//! receiver: java.util.List
//! receiverType: java.util.List<java.lang.Integer>
//! contains: size, get
package com.acme.cases;

import java.util.*;
import java.util.function.*;

class LamShapeValueBlockPicksFunction {
    static <R> List<R> collect(Function<String, R> f) { return null; }
    static List<String> collect(Consumer<String> c) { return null; }
    void test() {
        collect(s -> { return s.length(); })./*|*/
    }
}
