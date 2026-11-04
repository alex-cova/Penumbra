//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferFuture {
    void test() {
        CompletableFuture.supplyAsync(() -> "x").thenApply(String::length).get()./*|*/
    }
}
