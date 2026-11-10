//! top1: StringBuilder
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamIncConstructorInUnclosedBlock {
    static <T, R> R build(Supplier<R> s, BiConsumer<R, T> f) { return s.get(); }
    void test() {
        build(() -> new ArrayList<String>(), (l, v) -> { Object o = new StringBuild/*|*/
    }
}
