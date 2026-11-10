//! receiver: java.util.ArrayList
//! receiverType: java.util.ArrayList<T>
//! contains: size, add, ensureCapacity
//! excludes: skip, slice, sorted
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamCollectorOfAccumulator {
    static <T> Collector<T, ?, List<T>> taking(long n) {
        return Collector.of(
            () -> new ArrayList<T>(),
            (l, v) -> {
                l./*|*/
            },
            (l1, l2) -> {
                l1.addAll(l2);
                return l1;
            },
            Collections::unmodifiableList
        );
    }
}
