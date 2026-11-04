//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Cap9FunctionApplyExtends {
    void test() throws Exception {
        Function<? super String, ? extends Integer> f = null; f.apply("a")./*|*/
    }
}
