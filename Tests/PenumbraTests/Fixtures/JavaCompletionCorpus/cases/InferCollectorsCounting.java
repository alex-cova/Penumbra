//! receiver: java.lang.Long
//! contains: longValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferCollectorsCounting {
    void test() {
        Stream.of("a").collect(Collectors.groupingBy(s -> s, Collectors.counting())).get("a")./*|*/
    }
}
