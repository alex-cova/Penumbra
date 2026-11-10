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

class LamMapMergeRemapping {
    void test(Map<String, Integer> m) {
        m.merge("k", 1, (a, b) -> { a./*|*/ });
    }
}
