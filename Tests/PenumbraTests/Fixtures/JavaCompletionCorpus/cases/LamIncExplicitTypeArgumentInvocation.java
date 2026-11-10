//! receiver: java.lang.String
//! receiverType: java.lang.String
//! oracle-completion: zzProbe()));
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class LamIncExplicitTypeArgumentInvocation {
    void test(List<String> names) {
        Collections.<String>max(names, Comparator.comparing(s -> s./*|*/
    }
}
