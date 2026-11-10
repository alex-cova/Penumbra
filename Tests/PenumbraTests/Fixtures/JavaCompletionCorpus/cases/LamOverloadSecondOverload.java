//! receiver: java.lang.String
//! receiverType: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamOverloadSecondOverload {
    static void run(Runnable r) { }
    static <T> void run(Consumer<T> c, T value) { }
    void test() {
        run(s -> { s./*|*/ }, "x");
    }
}
