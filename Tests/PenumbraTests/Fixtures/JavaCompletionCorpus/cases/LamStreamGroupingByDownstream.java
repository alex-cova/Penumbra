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

class LamStreamGroupingByDownstream {
    void test() {
        Stream.of("a").collect(Collectors.groupingBy(String::length, Collectors.mapping(s -> { s./*|*/ }, Collectors.toList())));
    }
}
