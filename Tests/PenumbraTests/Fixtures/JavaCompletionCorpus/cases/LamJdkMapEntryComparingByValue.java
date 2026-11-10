//! receiver: java.util.Map.Entry
//! receiverType: java.util.Map.Entry<java.lang.String,java.lang.Integer>
//! contains: getKey
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamJdkMapEntryComparingByValue {
    void test(Map<String, Integer> m) {
        m.entrySet().stream().sorted(Map.Entry.comparingByValue()).map(e -> { e./*|*/ });
    }
}
