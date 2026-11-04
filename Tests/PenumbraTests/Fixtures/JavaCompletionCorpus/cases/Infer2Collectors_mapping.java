//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2Collectors_mapping {
    void test() throws Exception {
        Stream.of("a").collect(Collectors.groupingBy(s -> s.length(), Collectors.mapping(s -> s.trim(), Collectors.toList()))).get(1).get(0)./*|*/
    }
}
