//! receiver: java.util.Map.Entry
//! receiverType: java.util.Map.Entry<java.lang.String,java.lang.Integer>
//! contains: getKey, getValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamJdkMapEntryStream {
    void test(Map<String, Integer> m) {
        m.entrySet().stream().filter(e -> { e./*|*/ });
    }
}
