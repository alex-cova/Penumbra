//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferFunctionCompose {
    void test() {
        Function<String, Integer> f = String::length; Function<Integer, String> g = Object::toString; f.andThen(g).apply("a")./*|*/
    }
}
