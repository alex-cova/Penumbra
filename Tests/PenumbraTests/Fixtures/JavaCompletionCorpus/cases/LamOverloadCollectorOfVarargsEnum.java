//! receiver: java.util.ArrayList
//! receiverType: java.util.ArrayList<java.lang.String>
//! contains: size
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamOverloadCollectorOfVarargsEnum {
    void test() {
        Collector.of(() -> new ArrayList<String>(), (l, v) -> { l./*|*/ }, (a, b) -> a, Collections::unmodifiableList);
    }
}
