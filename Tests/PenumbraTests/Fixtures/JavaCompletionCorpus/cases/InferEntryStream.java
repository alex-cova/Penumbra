//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferEntryStream {
    void test() {
        Map<String, Integer> m = new HashMap<>(); m.entrySet().stream().map(Map.Entry::getKey).findFirst().get()./*|*/
    }
}
