//! receiver: java.util.List
//! receiverType: java.util.List<com.acme.model.User>
//! contains: size, stream
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamBiConsumerMapForEachValue {
    void test(Map<String, List<User>> m) {
        m.forEach((k, v) -> { v./*|*/ });
    }
}
