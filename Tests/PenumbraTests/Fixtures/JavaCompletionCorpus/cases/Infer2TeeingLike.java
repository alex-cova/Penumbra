//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2TeeingLike {
    void test() throws Exception {
        Stream.of(1, 2).collect(Collectors.summingInt(i -> i))./*|*/
    }
}
