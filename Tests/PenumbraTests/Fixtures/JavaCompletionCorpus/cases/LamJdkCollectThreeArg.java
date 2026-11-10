//! receiver: java.util.ArrayList
//! receiverType: java.util.ArrayList<java.lang.String>
//! contains: size, add
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamJdkCollectThreeArg {
    void test() {
        Stream.of("a").collect(() -> new ArrayList<String>(), (l, s) -> { l./*|*/ }, (a, b) -> a.addAll(b));
    }
}
