//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2MaxComparator {
    void test() throws Exception {
        List<String> l = new ArrayList<>(); Collections.max(l, Comparator.comparing(String::length))./*|*/
    }
}
