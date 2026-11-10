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

class LamWildcardExtendsSource {
    static <T> void each(Collection<? extends T> c, Consumer<? super T> f) { }
    void test(List<User> users) {
        each(users, u -> { u./*|*/ });
    }
}
