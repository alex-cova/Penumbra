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

class LamGenericFoldElement {
    static <T, R> R fold(Collection<T> c, R init, BiFunction<R, T, R> f) { return init; }
    void test(List<User> users) {
        fold(users, new StringBuilder(), (acc, u) -> { u./*|*/ });
    }
}
