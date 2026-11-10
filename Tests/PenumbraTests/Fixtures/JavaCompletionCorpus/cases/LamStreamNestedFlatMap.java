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

class LamStreamNestedFlatMap {
    void test(List<User> users) {
        Stream.of(users).flatMap(l -> l.stream().map(u -> { u./*|*/ }));
    }
}
