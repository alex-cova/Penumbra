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

class LamWildcardSuperComparator {
    static <T> void sortBy(List<T> l, Comparator<? super T> c) { }
    void test(List<User> users) {
        sortBy(users, (a, b) -> { a./*|*/ });
    }
}
