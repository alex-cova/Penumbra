//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2ConstructorRefSupplier {
    void test() throws Exception {
        Supplier<List<String>> s = ArrayList::new; s.get().get(0)./*|*/
    }
}
