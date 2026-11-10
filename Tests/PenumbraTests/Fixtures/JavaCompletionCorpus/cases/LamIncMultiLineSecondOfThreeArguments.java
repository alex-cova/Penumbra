//! receiver: java.lang.Integer
//! receiverType: java.lang.Integer
//! oracle-completion: zzProbe(); return n; });
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class LamIncMultiLineSecondOfThreeArguments {
    static <A, B, C> C pipe(A a, Function<A, B> f, Function<B, C> g) { return g.apply(f.apply(a)); }
    void test() {
        pipe("x", s -> { return s.length(); }, n -> {
            n./*|*/
    }
}
