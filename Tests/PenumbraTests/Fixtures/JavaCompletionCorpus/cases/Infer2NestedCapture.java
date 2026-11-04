//! receiver: java.lang.Number
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2NestedCapture {
    void test() throws Exception {
        Map<String, ? extends Collection<? extends Number>> m = new HashMap<>(); m.get("k").iterator().next()./*|*/
    }
}
