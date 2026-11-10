//! receiver: java.util.ArrayList
//! receiverType: java.util.ArrayList<java.lang.String>
//! contains: addAll
//! oracle-completion: zzProbe(); return x; }, l -> l);
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamIncSiblingsFinisherMissing {
    static <T, A, R> R collect3(Supplier<A> supplier, BiConsumer<A, T> accumulator, BinaryOperator<A> combiner,
            Function<A, R> finisher) { return finisher.apply(supplier.get()); }
    void test() {
        collect3(() -> new ArrayList<String>(), (l, v) -> l.add(v), (x, y) -> { x./*|*/
    }
}
