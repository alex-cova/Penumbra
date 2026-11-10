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

class LamGenericPipeFirstLambda {
    static <A, B, C> C pipe(A a, Function<A, B> f, Function<B, C> g) { return g.apply(f.apply(a)); }
    void test() {
        pipe("x", s -> { s./*|*/ }, n -> n);
    }
}
