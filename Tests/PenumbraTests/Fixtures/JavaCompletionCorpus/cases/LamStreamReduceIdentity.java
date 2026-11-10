//! receiver: java.lang.Integer
//! receiverType: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamStreamReduceIdentity {
    void test() {
        Stream.of(1, 2).reduce(0, (a, b) -> { a./*|*/ });
    }
}
