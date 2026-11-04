//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferStaticGenericFactory {
    void test() {
        Map<String, List<Integer>> m = new HashMap<>(); m.computeIfAbsent("k", k -> new ArrayList<>()).get(0)./*|*/
    }
}
