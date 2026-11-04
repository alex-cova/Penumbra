//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2StaticGenericMethodUser {
    static <T, R> R apply(T t, Function<T, R> f) { return f.apply(t); }
    void test() throws Exception {
        apply("a", s -> s.length())./*|*/
    }
}
