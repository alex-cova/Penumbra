//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2MapMerge {
    void test() throws Exception {
        Map<String, Integer> m = new HashMap<>(); m.merge("a", 1, Integer::sum)./*|*/
    }
}
