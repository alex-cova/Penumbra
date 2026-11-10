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

class LamArraysSortComparator {
    void test(String[] names) {
        Arrays.sort(names, (a, b) -> { a./*|*/ });
    }
}
