//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferGetOrDefault {
    void test() {
        Map<String, String> m = new HashMap<>(); m.getOrDefault("k", "d")./*|*/
    }
}
