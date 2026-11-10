//! receiver: java.lang.Integer
//! receiverType: java.lang.Integer
//! contains: intValue
//! oracle-completion: zzProbe(); return n; });
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamIncUnclosedBlockExplicitFirst {
    static <A, B, C> C pipe(A a, Function<A, B> f, Function<B, C> g) { return g.apply(f.apply(a)); }
    void test() {
        pipe("x", (String s) -> s.length(), n -> { n./*|*/
    }
}
