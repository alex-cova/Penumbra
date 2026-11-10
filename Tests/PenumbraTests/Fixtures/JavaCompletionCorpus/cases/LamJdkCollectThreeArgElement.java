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

class LamJdkCollectThreeArgElement {
    void test() {
        Stream.of("a").collect(() -> new ArrayList<String>(), (l, s) -> { s./*|*/ }, (a, b) -> a.addAll(b));
    }
}
