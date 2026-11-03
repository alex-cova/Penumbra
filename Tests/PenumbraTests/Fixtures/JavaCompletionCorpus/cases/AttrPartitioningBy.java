//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class AttrPartitioningBy {
    void test() {
        Map<Boolean, List<String>> m = Stream.of("a").collect(Collectors.partitioningBy(s -> s.isEmpty())); m.get(true).get(0)./*|*/
    }
}
