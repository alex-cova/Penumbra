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

class LamMapReplaceAll {
    void test(Map<String, Integer> m) {
        m.replaceAll((k, v) -> { v./*|*/ });
    }
}
