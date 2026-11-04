//! receiver: java.lang.Double
//! contains: doubleValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferBiFunction {
    void test() {
        BiFunction<String, Integer, Double> f = (s, i) -> 1.0; f.apply("a", 1)./*|*/
    }
}
