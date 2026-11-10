//! receiver: java.lang.Integer
//! receiverType: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamJdkCompletableFutureThenCombine {
    void test() {
        CompletableFuture.supplyAsync(() -> "x").thenCombine(CompletableFuture.supplyAsync(() -> 1), (a, b) -> { b./*|*/ });
    }
}
