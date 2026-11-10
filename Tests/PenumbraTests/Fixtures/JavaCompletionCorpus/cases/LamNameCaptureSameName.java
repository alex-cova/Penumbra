//! receiver: java.util.ArrayList
//! receiverType: java.util.ArrayList<T>
//! contains: size, add
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamNameCaptureSameName {
    static <T, R> R build(Supplier<R> s, BiConsumer<R, T> f) { return s.get(); }
    static <T> void m(T seed) {
        build(() -> new ArrayList<T>(), (l, v) -> { l./*|*/ });
    }
}
