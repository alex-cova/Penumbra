//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2PrimitiveBoxChain {
    void test() throws Exception {
        int[] a = {1}; Arrays.stream(a).boxed().collect(Collectors.toList()).get(0)./*|*/
    }
}
