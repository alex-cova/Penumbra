//! receiver: java.lang.Number
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Cap3ValuesNext {
    void test() throws Exception {
        Map<String, ? extends Number> m = new HashMap<String, Integer>(); m.values().iterator().next()./*|*/
    }
}
