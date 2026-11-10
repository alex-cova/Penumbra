//! receiver: java.util.List
//! receiverType: java.util.List<java.lang.String>
//! contains: size, get
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamJdkCollectingAndThen {
    void test() {
        Stream.of("a").collect(Collectors.collectingAndThen(Collectors.toList(), l -> { l./*|*/ }));
    }
}
