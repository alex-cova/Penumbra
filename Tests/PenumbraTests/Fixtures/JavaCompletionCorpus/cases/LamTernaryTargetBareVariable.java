//! receiver: java.lang.String
//! receiverType: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamTernaryTargetBareVariable {
    static <T> T make(Consumer<T> c) { return null; }
    void test() {
        String r = make(x -> { x./*|*/ });
    }
}
