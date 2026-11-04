//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2OptionalFlatMap {
    void test() throws Exception {
        Optional<String> o = Optional.empty(); o.flatMap(s -> Optional.of(s.length())).get()./*|*/
    }
}
