//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferForeachVar {
    void test() {
        for (var e : Map.of("a", 1).entrySet()) { e.getValue()./*|*/ }
    }
}
