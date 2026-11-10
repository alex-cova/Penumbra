//! receiver: java.util.ArrayList
//! receiverType: java.util.ArrayList<java.lang.String>
//! contains: size, add
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamOverloadFunctionalVersusPlain {
    static <T, A, R> R build(Supplier<A> s, BiConsumer<A, T> f, Function<A, R> finisher) { return finisher.apply(s.get()); }
    static <T, R> R build(Supplier<R> s, BiConsumer<R, T> f, Thread.State... ignored) { return s.get(); }
    void test() {
        build(() -> new ArrayList<String>(), (l, v) -> { l./*|*/ }, Collections::unmodifiableList);
    }
}
