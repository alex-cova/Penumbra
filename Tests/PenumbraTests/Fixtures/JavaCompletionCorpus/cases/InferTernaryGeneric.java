//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferTernaryGeneric {
    void test() {
        boolean f = true; List<String> a = new ArrayList<>(); List<String> b = new LinkedList<>(); (f ? a : b).get(0)./*|*/
    }
}
