//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2LambdaNestedParam {
    void test() throws Exception {
        List<List<String>> l = new ArrayList<>(); l.forEach(inner -> inner.forEach(s -> s./*|*/));
    }
}
