//! receiver: java.lang.String
//! receiverType: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamOverloadByLambdaArity {
    static <T> T pick(Supplier<T> s) { return s.get(); }
    static <T> T pick(Function<String, T> f) { return f.apply(""); }
    void test() {
        pick(s -> { s./*|*/ });
    }
}
