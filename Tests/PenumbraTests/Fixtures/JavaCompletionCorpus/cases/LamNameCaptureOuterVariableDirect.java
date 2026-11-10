//! receiver: java.lang.Comparable
//! receiverType: java.lang.Comparable<T>
//! oracle: javac names the variable (T); the engine reports its single bound, as Cap15BoundedTypeVar does
//! contains: compareTo
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamNameCaptureOuterVariableDirect {
    static <T, R> R build(Supplier<R> s, BiConsumer<R, T> f) { return s.get(); }
    static <T extends Comparable<T>> void m(T seed) {
        build(() -> seed, (l, v) -> { l./*|*/ });
    }
}
