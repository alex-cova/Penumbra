//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Cap10MapEntrySetStream {
    void test() throws Exception {
        Map<String, ? extends List<Integer>> m = new HashMap<>(); m.entrySet().stream().map(e -> e.getValue()).findFirst().get().get(0)./*|*/
    }
}
