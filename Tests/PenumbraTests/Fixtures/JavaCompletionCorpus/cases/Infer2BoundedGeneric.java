//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2BoundedGeneric {
    static <T extends Comparable<T>> T best(List<T> l) { return null; }
    void test() throws Exception {
        best(List.of("a"))./*|*/
    }
}
