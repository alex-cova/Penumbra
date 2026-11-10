//! receiver: java.lang.Integer
//! receiverType: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamShapeConsumerVersusFunctionValue {
    static void each(Consumer<String> c) { }
    static <R> R each(Function<String, R> f) { return null; }
    void test() {
        each(s -> { return s.length(); })./*|*/
    }
}
