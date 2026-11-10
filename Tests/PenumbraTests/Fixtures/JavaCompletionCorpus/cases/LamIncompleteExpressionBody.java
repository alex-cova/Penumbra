//! receiver: java.lang.StringBuilder
//! receiverType: java.lang.StringBuilder
//! oracle-completion: zzProbe());
//! contains: append
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamIncompleteExpressionBody {
    static <T, R> R build(Supplier<R> s, BiConsumer<R, T> f) { return s.get(); }
    void test() {
        build(StringBuilder::new, (sb, v) -> sb./*|*/
    }
}
