//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2CompletableFutureAllOf {
    void test() throws Exception {
        CompletableFuture<String> f = new CompletableFuture<>(); f.thenCombine(CompletableFuture.completedFuture(1), (a, b) -> a.length() + b).get()./*|*/
    }
}
