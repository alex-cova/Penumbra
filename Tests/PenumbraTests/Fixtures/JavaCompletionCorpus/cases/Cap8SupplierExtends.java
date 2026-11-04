//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Cap8SupplierExtends {
    void test() throws Exception {
        Supplier<? extends List<String>> s = null; s.get().get(0)./*|*/
    }
}
