//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferCollectorsToMap {
    void test() {
        Stream.of("a").collect(Collectors.toMap(s -> s, s -> s.length())).get("a")./*|*/
    }
}
