//! receiver: java.util.List
//! receiverType: java.util.List<com.acme.model.User>
//! contains: size
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamMapComputeIfPresentValue {
    void test(Map<String, List<User>> m) {
        m.computeIfPresent("k", (k, v) -> { v./*|*/ });
    }
}
