//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2ComparingByValue {
    void test() throws Exception {
        Map<String, Integer> m = new HashMap<>(); m.entrySet().stream().max(Map.Entry.comparingByValue()).get().getKey()./*|*/
    }
}
