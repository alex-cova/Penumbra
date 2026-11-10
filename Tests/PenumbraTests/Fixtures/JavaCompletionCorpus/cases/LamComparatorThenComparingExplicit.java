//! receiver: com.acme.model.User
//! receiverType: com.acme.model.User
//! contains: getName
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamComparatorThenComparingExplicit {
    void test() {
        Comparator.comparing((User u) -> u.getName()).thenComparing(u -> { u./*|*/ });
    }
}
