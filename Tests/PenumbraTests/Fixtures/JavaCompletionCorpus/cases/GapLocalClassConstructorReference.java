//! contains: list
package com.acme.cases;

import java.util.*;
import java.util.function.*;

class GapLocalClassConstructorReference {
    static <T, R> R build(Supplier<R> s, BiConsumer<R, T> f) { return s.get(); }
    void test() {
        class Acc { List<String> list; }
        build(Acc::new, (a, v) -> { a./*|*/; });
    }
}
