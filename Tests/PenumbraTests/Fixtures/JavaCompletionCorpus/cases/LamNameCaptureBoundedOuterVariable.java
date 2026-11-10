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

class LamNameCaptureBoundedOuterVariable {
    static <T> void each(Collection<? extends T> c, Consumer<? super T> f) { }
    static <T extends Comparable<T>> void m(List<T> list) {
        each(list, x -> { x./*|*/ });
    }
}
