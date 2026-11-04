//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2RecordAccessor {
    record P(String name, List<Integer> xs) {}
    void test() throws Exception {
        P p = null; p.xs().get(0)./*|*/
    }
}
