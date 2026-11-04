//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferCollectToList {
    void test() {
        List<Integer> r = Stream.of("a").map(s -> s.length()).collect(Collectors.toList()); r.get(0)./*|*/
    }
}
