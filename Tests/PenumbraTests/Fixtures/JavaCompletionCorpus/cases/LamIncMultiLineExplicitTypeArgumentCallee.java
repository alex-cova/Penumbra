//! receiver: java.lang.String
//! receiverType: java.lang.String
//! oracle-completion: zzProbe(); return s; });
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class LamIncMultiLineExplicitTypeArgumentCallee {
    void test() {
        Optional.<String>of("x").map(s -> {
            s./*|*/
    }
}
