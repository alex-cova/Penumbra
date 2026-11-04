//! receiver: java.lang.Number
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Cap1StreamLambdaParam {
    void test() throws Exception {
        List<? extends Number> l = new ArrayList<Integer>(); l.stream().map(n -> n./*|*/);
    }
}
