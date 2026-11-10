//! receiver: java.util.ArrayList
//! receiverType: java.util.ArrayList<java.lang.String>
//! oracle-completion: zzProbe();
//! contains: size, add
package com.acme.cases;

import com.acme.model.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class LamIncTailBlockAlreadyClosed {
    static <T, R> R build(Supplier<R> s, BiConsumer<R, T> f) { return s.get(); }
    void test() {
        build(() -> new ArrayList<String>(), (l, v) -> { l./*|*/
            l.add(String.valueOf(v));
        });
    }
}
