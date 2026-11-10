//! receiver: java.util.List
//! receiverType: java.util.List<java.lang.String>
//! contains: size, get
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamBoundedTypeVariableValue {
    static <K, V extends Collection<K>> void visit(Map<K, V> m, BiConsumer<K, V> f) { }
    void test(Map<String, List<String>> m) {
        visit(m, (k, v) -> { v./*|*/ });
    }
}
