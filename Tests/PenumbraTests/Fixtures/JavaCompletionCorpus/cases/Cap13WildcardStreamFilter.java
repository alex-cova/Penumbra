//! receiver: java.lang.Number
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Cap13WildcardStreamFilter {
    void test() throws Exception {
        List<? extends Number> l = null; l.stream().filter(n -> n.intValue() > 0).findFirst().get()./*|*/
    }
}
